#!/usr/bin/env python3
"""Live test: a SILENT raw-SSH client through the real HAProxy dispatch.

Proves the full path a raw SSH-over-TLS client takes on the server:
  client -> HAProxy dispatch (10444, TLS already terminated upstream)
       -> ws-proxy (PROXY port) -> Dropbear (fake SSH target)

The client sends NOTHING after connecting (it waits for the server
banner, as SSH requires). The dispatch must route it to ws-proxy
(the is_silent ACL), NOT to the HTTP frontend/nginx, or the banner
never arrives and the client gives up after ~5s ("Premature
connection close").

Setup (all on 127.0.0.1, high ports, nothing touches the real server):
  - fake SSH target on 1109: sends "SSH-2.0-dropbear_2020.81" on connect
  - real scripts/ws-proxy.py on 18080 (plain) / 18081 (PROXY)
  - real HAProxy 2.8 with a minimal config replicating the dispatch
    frontend from templates/haproxy.cfg.tpl (inspect-delay 2s +
    is_raw_ssh / is_sshws_req / is_silent ACLs)
  - the test client sends a PROXY header (as https_dispatch_in does
    in production) then nothing, and waits for the banner.

Exit 0 + "ALL TESTS PASSED" = the dispatch routes silent clients to
ws-proxy and the banner arrives. Any other exit = the path is broken.
"""
import os
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS_PROXY = os.path.join(HERE, "scripts", "ws-proxy.py")
FAKE_SSH_PORT = 11109
WS_PLAIN = 18080
WS_PROXY_PORT = 18081
DISPATCH_PORT = 10444
BANNER = b"SSH-2.0-dropbear_2020.81\r\n"
HAPROXY_CFG = "/tmp/ws-proxy-dispatch-test/haproxy.cfg"
HAPROXY_PID = "/tmp/ws-proxy-dispatch-test/haproxy.pid"


def _fake_ssh_conn(conn, stop):
    try:
        conn.sendall(BANNER)
        conn.settimeout(0.5)
        while not stop.is_set():
            try:
                data = conn.recv(4096)
            except socket.timeout:
                continue
            if not data:
                break
            conn.sendall(b"ECHO:" + data)
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def fake_ssh_target(stop):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", FAKE_SSH_PORT))
    srv.listen(5)
    srv.settimeout(0.5)
    while not stop.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        threading.Thread(target=_fake_ssh_conn, args=(conn, stop),
                         daemon=True).start()
    srv.close()


def recv_until(sock, needle, timeout):
    sock.settimeout(timeout)
    buf = b""
    start = time.time()
    try:
        while needle not in buf and time.time() - start < timeout:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    return buf


def write_haproxy_cfg():
    os.makedirs(os.path.dirname(HAPROXY_CFG), exist_ok=True)
    cfg = """global
    daemon
    maxconn 64
    stats socket /tmp/ws-proxy-dispatch-test/stats.sock mode 600 level admin
    pidfile %s

defaults
    mode tcp
    timeout connect 5s
    timeout client 10s
    timeout server 10s

frontend https_dispatch
    mode tcp
    bind 127.0.0.1:%d accept-proxy
    timeout client 10s
    tcp-request inspect-delay 2s
    tcp-request content accept if { payload(0,10) -m len 10 }
    acl is_raw_ssh payload(0,4) -m str "SSH-"
    acl is_sshws_req payload(0,10) -m str "GET /sshws"
    acl has_payload payload(0,1) -m found
    use_backend ws_proxy_raw if is_raw_ssh
    use_backend ws_proxy_raw if is_sshws_req
    use_backend ws_proxy_raw if !has_payload
    default_backend https_http_in

backend ws_proxy_raw
    mode tcp
    timeout server 10s
    server ws 127.0.0.1:%d send-proxy

backend https_http_in
    mode tcp
    timeout server 10s
    # Nothing listens here on purpose: if the dispatch misroutes a
    # silent client to the HTTP frontend, the connect fails and the
    # test below sees no banner (FAIL), instead of hanging on nginx.
    server dead 127.0.0.1:19999
""" % (HAPROXY_PID, DISPATCH_PORT, WS_PROXY_PORT)
    with open(HAPROXY_CFG, "w") as f:
        f.write(cfg)


def wait_port(port, timeout=5.0):
    start = time.time()
    while time.time() - start < timeout:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=0.5)
            s.close()
            return True
        except OSError:
            time.sleep(0.1)
    return False


def main():
    stop = threading.Event()
    threading.Thread(target=fake_ssh_target, args=(stop,), daemon=True).start()
    env = dict(os.environ)
    env["WS_PROXY_PORT"] = str(WS_PLAIN)
    env["WS_PROXY_PROXY_PORT"] = str(WS_PROXY_PORT)
    env["SSH_PORT_INTERNAL"] = str(FAKE_SSH_PORT)
    env["VPSMGR_DATA_DIR"] = "/tmp/ws-proxy-dispatch-test-data"
    proc = subprocess.Popen(
        [sys.executable, WS_PROXY], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    haproxy = None
    try:
        time.sleep(1.0)
        if not wait_port(WS_PLAIN, 5.0):
            print("FAIL: ws-proxy did not start")
            return 1
        write_haproxy_cfg()
        # Validate the test config first (same check as production).
        chk = subprocess.run(["haproxy", "-c", "-f", HAPROXY_CFG],
                             capture_output=True, text=True)
        if chk.returncode != 0:
            print("FAIL: test haproxy config invalid:\n%s" % chk.stderr)
            return 1
        haproxy = subprocess.Popen(["haproxy", "-f", HAPROXY_CFG],
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        if not wait_port(DISPATCH_PORT, 5.0):
            print("FAIL: haproxy dispatch did not start")
            return 1

        print("Test: silent client through HAProxy dispatch (sends nothing, waits for banner)...")
        c = socket.create_connection(("127.0.0.1", DISPATCH_PORT), timeout=10)
        try:
            # What https_dispatch_in sends in production: a PROXY header,
            # then the (empty) payload. The client then sends nothing.
            c.sendall(b"PROXY TCP4 203.0.113.7 127.0.0.1 54321 10444\r\n")
            start = time.time()
            got = recv_until(c, b"SSH-2.0-", 6.0)
            elapsed = time.time() - start
            if b"SSH-2.0-" in got:
                print("  PASS: banner received through dispatch in %.2fs: %r" % (elapsed, got[:32]))
                if elapsed > 5.0:
                    print("  WARN: banner took %.2fs - close to the client's ~5s give-up" % elapsed)
            else:
                print("  FAIL: no banner within 6s (got %r) - silent client never reached ws-proxy / Dropbear" % got)
                return 1
            # The tunnel must also carry the client's version string back.
            c.sendall(b"SSH-2.0-HTTP-Custom\r\n")
            echo = recv_until(c, b"ECHO:SSH-2.0-HTTP-Custom", 3.0)
            if b"ECHO:SSH-2.0-HTTP-Custom" in echo:
                print("  PASS: client version string round-tripped through dispatch + ws-proxy")
            else:
                print("  FAIL: version string did not round-trip (got %r)" % echo)
                return 1
        finally:
            c.close()
        print("ALL TESTS PASSED")
        return 0
    finally:
        stop.set()
        if haproxy is not None:
            haproxy.terminate()
            try:
                haproxy.wait(timeout=5)
            except Exception:
                haproxy.kill()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
