#!/usr/bin/env python3
"""Test the ws-proxy raw-SSH deadlock fix.

Scenario: a raw SSH client over TLS sends NOTHING first - it waits for the
server banner. The old ws-proxy blocked forever in read_head() waiting for
client bytes (deadlock -> client gave up after ~5s, "Premature connection
close"). The fix: a 2s timeout on the first read; silence means raw SSH
waiting for the server banner, so connect to the target and let its banner
reach the client.

The test spins up:
  - a fake SSH target on 127.0.0.1:1109 that sends "SSH-2.0-dropbear_2020.81\r\n"
    as soon as a client connects (like Dropbear does), then echoes back
    anything the client sends;
  - the real ws-proxy (scripts/ws-proxy.py) with TARGET=127.0.0.1:1109,
    plain listener on 18080, PROXY listener on 18081;
  - a client that connects to the PLAIN listener and sends NOTHING,
    waiting for the server banner.

PASS = the silent client receives the SSH banner within 4s (well inside
the client's ~5s give-up window). FAIL = no banner within 4s (deadlock).
A second check confirms the normal WebSocket path still works.
"""
import os
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS_PROXY = os.path.join(HERE, "scripts", "ws-proxy.py")
FAKE_SSH_PORT = 1109
PLAIN_PORT = 18080
PROXY_PORT = 18081
BANNER = b"SSH-2.0-dropbear_2020.81\r\n"


def _fake_ssh_conn(conn, stop):
    # Dropbear sends its banner immediately on connect.
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
        # Each connection in its own thread, so a lingering Test 1
        # connection cannot block Test 2's accept.
        threading.Thread(target=_fake_ssh_conn, args=(conn, stop),
                         daemon=True).start()
    srv.close()


def recv_until(sock, needle, timeout):
    sock.settimeout(timeout)
    buf = b""
    try:
        while needle not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    return buf


def main():
    stop = threading.Event()
    t = threading.Thread(target=fake_ssh_target, args=(stop,), daemon=True)
    t.start()

    env = dict(os.environ)
    env["WS_PROXY_PORT"] = str(PLAIN_PORT)
    env["WS_PROXY_PROXY_PORT"] = str(PROXY_PORT)
    env["SSH_PORT_INTERNAL"] = str(FAKE_SSH_PORT)
    env["VPSMGR_DATA_DIR"] = "/tmp/ws-proxy-test-data"
    proc = subprocess.Popen(
        [sys.executable, WS_PROXY], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        # Give the interpreter a moment to start before probing the port.
        time.sleep(1.0)
        # Wait for both listeners to come up.
        up = False
        for _ in range(50):
            try:
                s = socket.create_connection(("127.0.0.1", PLAIN_PORT), timeout=0.2)
                s.close()
                up = True
                break
            except OSError:
                time.sleep(0.1)
        if not up:
            proc.terminate()
            try:
                out, _ = proc.communicate(timeout=3)
            except Exception:
                out = "(no output captured)"
            print("FAIL: ws-proxy did not start; its output:\n%s" % out)
            return 1

        # --- Test 1: silent raw-SSH client (the deadlock case) ---
        print("Test 1: silent client (sends nothing, waits for server banner)...")
        c = socket.create_connection(("127.0.0.1", PLAIN_PORT), timeout=5)
        t0 = time.time()
        got = recv_until(c, b"SSH-2.0-", 4.0)
        dt = time.time() - t0
        if BANNER in got:
            print("  PASS: banner received in %.2fs: %r" % (dt, got[:40]))
        else:
            print("  FAIL: no banner within 4s (got %r) - deadlock NOT fixed" % got[:80])
            c.close()
            return 1
        # Client now sends its version string; the target echoes it back.
        c.sendall(b"SSH-2.0-HTTP-Custom\r\n")
        echo = recv_until(c, b"ECHO:SSH-2.0-HTTP-Custom", 3.0)
        if b"ECHO:SSH-2.0-HTTP-Custom" in echo:
            print("  PASS: client version string round-tripped through the tunnel")
        else:
            print("  FAIL: version string did not round-trip (got %r)" % echo[:80])
            c.close()
            return 1
        c.close()

        # --- Test 2: normal WebSocket handshake still works ---
        print("Test 2: WebSocket handshake (GET /sshws + Upgrade)...")
        import base64, hashlib
        key = base64.b64encode(b"testkey1234567890").decode()
        c2 = socket.create_connection(("127.0.0.1", PLAIN_PORT), timeout=5)
        c2.sendall(("GET /sshws HTTP/1.1\r\nHost: s7.ddkvps.xyz\r\n"
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    "Sec-WebSocket-Key: %s\r\n\r\n" % key).encode())
        resp = recv_until(c2, b"\r\n\r\n", 3.0)
        if b"101 Switching Protocols" in resp:
            print("  PASS: 101 Switching Protocols received")
        else:
            print("  FAIL: no 101 (got %r)" % resp[:120])
            c2.close()
            return 1
        # After the 101, the target banner should arrive through the tunnel.
        banner2 = recv_until(c2, b"SSH-2.0-", 3.0)
        if BANNER in banner2:
            print("  PASS: SSH banner arrived after the 101")
        else:
            print("  FAIL: no banner after 101 (got %r)" % banner2[:80])
            c2.close()
            return 1
        c2.close()

        print("ALL TESTS PASSED")
        return 0
    finally:
        stop.set()
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    sys.exit(main())
