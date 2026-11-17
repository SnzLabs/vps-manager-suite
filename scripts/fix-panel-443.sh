#!/usr/bin/env bash
# VPS Manager Suite - Put the web panel on the main domain, port 443
#
# Problem: the panel on :9090 is flaky from the outside on some VPS
# networks (TCP connects but the TLS/HTTP answer often never arrives,
# while port 443 answers every time). The panel itself is fine - it
# answers correctly on localhost - so the fix is to reach it through
# the reliable 443 path instead of :9090.
#
# What this does (run once as root):
#   1. Adds an HAProxy route: any HTTPS path on the main domain that is
#      NOT a VPN/Xray path (/vmess, /vless, /trojan, /sshws, /xhttp*)
#      goes to the panel (127.0.0.1:9090, TLS bridging). So the panel
#      opens at https://<domain>/ - no :9090, no second domain, no DNS
#      change, no new certificate (HAProxy already serves the main
#      domain's cert on 443). The VPN on 443 is untouched.
#   2. Validates the HAProxy config BEFORE reloading (a bad config is
#      never loaded - the old config is restored and the script aborts).
#   3. Tests https://<domain>/ (expect 302 -> /login), /login (200),
#      and a VPN path (400 = Xray answering), and prints a summary.
#
# Usage:  bash fix-panel-443.sh [domain]
#   The domain defaults to the one in /var/lib/vps-manager/config.json.
#   Idempotent: safe to re-run; it skips work that is already done.
#
# :9090 keeps working as before - this only ADDS the 443 address.
set -u
REPO_RAW="https://raw.githubusercontent.com/SnzLabs/vps-manager-suite/main"
CONFIG_DIR="${VPSMGR_CONFIG_DIR:-/etc/vps-manager}"
DATA_DIR="${VPSMGR_DATA_DIR:-/var/lib/vps-manager}"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"

say()  { echo "[fix-panel-443] $*"; }
ok()   { echo "[fix-panel-443] [OK] $*"; }
warn() { echo "[fix-panel-443] [WARN] $*" >&2; }
err()  { echo "[fix-panel-443] [ERROR] $*" >&2; }

[[ "$(id -u)" == "0" ]] || { err "Run this as root (sudo bash fix-panel-443.sh)."; exit 1; }

# --- 1. Domain ---------------------------------------------------------------
DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  DOMAIN="$(python3 -c "import json;print(json.load(open('$DATA_DIR/config.json')).get('domain',''))" 2>/dev/null || echo "")"
fi
[[ -n "$DOMAIN" ]] || { err "No domain found (tried $DATA_DIR/config.json). Run: bash fix-panel-443.sh <your-domain>"; exit 1; }
say "Domain: $DOMAIN  |  Panel address after the fix: https://$DOMAIN/"

# --- 2. The panel must be up on localhost :9090 -------------------------------
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet vps-panel 2>/dev/null; then
  warn "vps-panel is not active - trying to start it (systemctl start vps-panel)..."
  systemctl start vps-panel 2>/dev/null || true
fi
LOCAL_CODE="$(curl -sk --max-time 8 -o /dev/null -w '%{http_code}' "https://127.0.0.1:9090/" 2>/dev/null || echo 000)"
if [[ "$LOCAL_CODE" != "302" ]]; then
  err "The panel does not answer on localhost :9090 (got HTTP $LOCAL_CODE, expected 302)."
  echo "    Diagnose on the server: systemctl status vps-panel | journalctl -u vps-panel -n 30 --no-pager"
  exit 1
fi
ok "Panel answers on localhost :9090 (HTTP $LOCAL_CODE)"

# --- 3. Already done? (idempotent re-run) ------------------------------------
if grep -q "use_backend panel_backend if !is_router_path" "$HAPROXY_CFG" 2>/dev/null; then
  say "The panel-on-443 route is already in the HAProxy config - verifying only."
else
  say "Panel route in HAProxy config: no - adding it now."
  # Find the updated template: this repo's copy first, then GitHub raw.
  TPL=""
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for cand in "$HERE/../templates/haproxy.cfg.tpl" "/root/vps-manager-suite/templates/haproxy.cfg.tpl" "/opt/vps-manager-suite/templates/haproxy.cfg.tpl"; do
    [[ -f "$cand" ]] && grep -q "use_backend panel_backend if !is_router_path" "$cand" && { TPL="$cand"; break; }
  done
  if [[ -z "$TPL" ]]; then
    say "Downloading the updated HAProxy template from GitHub..."
    if curl -fsSL "$REPO_RAW/templates/haproxy.cfg.tpl" -o /tmp/haproxy.cfg.tpl \
       && grep -q "use_backend panel_backend if !is_router_path" /tmp/haproxy.cfg.tpl; then
      TPL="/tmp/haproxy.cfg.tpl"
    else
      err "Could not get the updated HAProxy template (needs the panel_backend route)."
      echo "    Check the internet connection, or update the repo first (git pull) and re-run."
      exit 1
    fi
  else
    say "Using local template: $TPL"
  fi
  WS_PORT="$(python3 -c "import json;print(json.load(open('$DATA_DIR/config.json')).get('ws_proxy_port',8080))" 2>/dev/null || echo 8080)"
  WS_PROXY_PORT="$((WS_PORT + 1))"
  TS="$(date +%Y%m%d-%H%M%S)"
  cp "$HAPROXY_CFG" "$HAPROXY_CFG.bak.$TS" 2>/dev/null || { err "Could not back up $HAPROXY_CFG."; exit 1; }
  say "Backed up the current HAProxy config to $HAPROXY_CFG.bak.$TS"
  sed "s/__DOMAIN__/$DOMAIN/g; s/__WSPROXY_PORT__/$WS_PORT/g; s/__WSPROXY_PROXY_PORT__/$WS_PROXY_PORT/g" "$TPL" > "$HAPROXY_CFG" \
    || { err "Could not write $HAPROXY_CFG."; exit 1; }
  # Validate BEFORE reloading: a bad config must never be loaded.
  if ! haproxy -c -f "$HAPROXY_CFG" >/dev/null 2>&1; then
    err "HAProxy config check FAILED - restoring the previous config, nothing was reloaded."
    cp "$HAPROXY_CFG.bak.$TS" "$HAPROXY_CFG"
    haproxy -c -f "$HAPROXY_CFG" 2>&1 | tail -n 10
    exit 1
  fi
  ok "HAProxy config check passed (panel route added)"
fi

# --- 4. Reload HAProxy + verify it is up --------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null || true
  if systemctl is-active --quiet haproxy; then
    ok "HAProxy is active"
  else
    err "HAProxy is NOT active after reload - diagnose: systemctl status haproxy | journalctl -u haproxy -n 30 --no-pager"
    exit 1
  fi
fi

# --- 5. Live tests -------------------------------------------------------------
say "Testing the panel on 443..."
PANEL_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null || echo 000)"
LOGIN_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$DOMAIN/login" 2>/dev/null || echo 000)"
VMESS_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$DOMAIN/vmess" 2>/dev/null || echo 000)"
echo "    https://$DOMAIN/        -> HTTP $PANEL_CODE (expect 302, the login redirect)"
echo "    https://$DOMAIN/login   -> HTTP $LOGIN_CODE (expect 200, the login page)"
echo "    https://$DOMAIN/vmess   -> HTTP $VMESS_CODE (expect 400, Xray answering - VPN untouched)"
echo
if [[ "$PANEL_CODE" == "302" && "$LOGIN_CODE" == "200" ]]; then
  ok "DONE - the panel is live at https://$DOMAIN/ (port 443, no :9090 needed)."
  echo "    Just open https://$DOMAIN/ in the browser - the panel login shows."
  echo "    The old address https://$DOMAIN:9090 still works as a fallback."
else
  warn "The panel did not answer as expected on 443 (panel / = $PANEL_CODE, /login = $LOGIN_CODE)."
  echo "    HAProxy is running and the config is valid; check: journalctl -u haproxy -n 30 --no-pager"
  exit 1
fi
