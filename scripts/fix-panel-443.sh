#!/usr/bin/env bash
# VPS Manager Suite - Put the web panel on port 443 (panel.<domain>)
#
# Problem: the panel on :9090 is flaky from the outside on some VPS
# networks (TCP connects but the TLS/HTTP answer often never arrives,
# while port 443 answers every time). The panel itself is fine - it
# answers correctly on localhost - so the fix is to reach it through
# the reliable 443 path instead of :9090.
#
# What this does (run once as root, AFTER adding the DNS record):
#   1. Issues a Let's Encrypt certificate for panel.<domain>
#      (needs the DNS A record panel.<domain> -> this server to exist
#      and resolve first - see step 0 below).
#   2. Appends that cert to HAProxy's TLS bundle (haproxy.pem) so
#      HAProxy serves the right certificate per SNI.
#   3. Adds an HAProxy route: SNI panel.<domain> on 443 -> the panel
#      (127.0.0.1:9090, TLS bridging). The VPN on 443 is untouched.
#   4. Installs the lineage-aware cert renewal hook so the panel cert
#      renews without ever overwriting the main-domain cert.
#   5. Validates the HAProxy config BEFORE reloading (a bad config is
#      never loaded - the old config is restored and the script aborts).
#   6. Tests https://panel.<domain>/ (expect 302 -> /login) and the
#      main domain + a VPN path, and prints a summary.
#
# Step 0 (do this FIRST, in your domain's DNS panel):
#   Add an A record:  panel.<your-domain>  ->  <this server's public IP>
#   Wait a few minutes for it to propagate, then run this script.
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
SSL_DIR="$CONFIG_DIR/ssl"
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
PANEL_HOST="panel.$DOMAIN"
say "Domain: $DOMAIN  |  Panel address: https://$PANEL_HOST"

# --- 2. DNS must resolve first ----------------------------------------------
PANEL_IP="$(getent hosts "$PANEL_HOST" 2>/dev/null | awk '{print $1}' | head -n1)"
if [[ -z "$PANEL_IP" ]]; then
  err "panel.$DOMAIN does not resolve yet."
  echo "    Add a DNS A record first:  panel.$DOMAIN  ->  this server's public IP"
  echo "    (in your domain's DNS panel, where $DOMAIN itself is managed),"
  echo "    wait a few minutes, then re-run this script."
  exit 1
fi
ok "DNS resolves: $PANEL_HOST -> $PANEL_IP"

# --- 3. The panel must be up on localhost :9090 -------------------------------
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

# --- 4. Already done? (idempotent re-run) ------------------------------------
ALREADY_CFG=0; ALREADY_CERT=0
grep -q "panel_backend" "$HAPROXY_CFG" 2>/dev/null && ALREADY_CFG=1
[[ -s "$SSL_DIR/panel-fullchain.pem" && -s "$SSL_DIR/panel-privkey.pem" ]] && ALREADY_CERT=1
if [[ "$ALREADY_CFG" == "1" && "$ALREADY_CERT" == "1" ]]; then
  say "Panel route + certificate are already in place - verifying only."
else
  say "Panel route in HAProxy config: $([[ $ALREADY_CFG == 1 ]] && echo yes || echo no) | Panel cert: $([[ $ALREADY_CERT == 1 ]] && echo yes || echo no)"
fi

# --- 5. Panel certificate ------------------------------------------------------
# certbot --standalone needs port 80 free: stop haproxy+nginx, and bring
# them back on EVERY exit path (same contract as lib/common.sh issue_ssl).
restore_web_stack() {
  if command -v systemctl >/dev/null 2>&1; then
    for s in haproxy nginx; do systemctl restart "$s" 2>/dev/null || true; done
    for s in haproxy nginx; do
      systemctl is-active --quiet "$s" 2>/dev/null || err "$s is NOT running after restore - diagnose: systemctl status $s | journalctl -u $s -n 30 --no-pager"
    done
  fi
}
if [[ "$ALREADY_CERT" != "1" ]]; then
  if ! command -v certbot >/dev/null 2>&1; then
    say "certbot not found - installing it..."
    (apt-get update -qq && apt-get install -y -qq certbot) >/dev/null 2>&1 || true
  fi
  command -v certbot >/dev/null 2>&1 || { err "certbot is not installed and could not be installed (apt-get install -y certbot)."; exit 1; }
  # Reuse an existing Let's Encrypt lineage for the panel host if one is
  # already there and valid; otherwise issue a fresh one.
  LE_DIR="/etc/letsencrypt/live/$PANEL_HOST"
  if [[ -s "$LE_DIR/fullchain.pem" && -s "$LE_DIR/privkey.pem" ]]; then
    say "Found an existing Let's Encrypt cert for $PANEL_HOST - reusing it."
  else
    say "Issuing a Let's Encrypt certificate for $PANEL_HOST (stops haproxy+nginx briefly for port 80)..."
    (
    trap 'restore_web_stack' EXIT
    trap 'restore_web_stack; exit 130' INT
    trap 'restore_web_stack; exit 143' TERM
    systemctl stop haproxy nginx 2>/dev/null || true
    if certbot certonly --standalone -d "$PANEL_HOST" --non-interactive --agree-tos -m "admin@$DOMAIN" >"/var/log/vps-manager-panel-certbot.log" 2>&1 \
       && [[ -s "$LE_DIR/fullchain.pem" && -s "$LE_DIR/privkey.pem" ]]; then
      exit 0
    fi
    err "Panel SSL FAILED for $PANEL_HOST - see /var/log/vps-manager-panel-certbot.log"
    echo "    Most common cause: the DNS A record panel.$DOMAIN is not pointing at this server yet."
    exit 1
    ) || exit 1
    restore_web_stack
  fi
  mkdir -p "$SSL_DIR"
  cp "$LE_DIR/fullchain.pem" "$SSL_DIR/panel-fullchain.pem" || { err "Could not copy the panel certificate."; exit 1; }
  cp "$LE_DIR/privkey.pem" "$SSL_DIR/panel-privkey.pem" || { err "Could not copy the panel private key."; exit 1; }
  chmod 600 "$SSL_DIR/panel-privkey.pem" 2>/dev/null || true
  ok "Panel certificate installed ($SSL_DIR/panel-fullchain.pem)"
fi

# --- 6. Rebuild the HAProxy TLS bundle (main + panel cert) --------------------
if [[ -s "$SSL_DIR/fullchain.pem" && -s "$SSL_DIR/privkey.pem" ]]; then
  cat "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" > "$SSL_DIR/haproxy.pem" 2>/dev/null || { err "Could not rebuild haproxy.pem."; exit 1; }
  cat "$SSL_DIR/panel-fullchain.pem" "$SSL_DIR/panel-privkey.pem" >> "$SSL_DIR/haproxy.pem" 2>/dev/null || true
  chmod 600 "$SSL_DIR/haproxy.pem" 2>/dev/null || true
  ok "HAProxy TLS bundle rebuilt (main domain + panel subdomain)"
else
  err "Main certificate pair missing ($SSL_DIR/fullchain.pem) - the suite SSL is not set up."
  exit 1
fi

# --- 7. HAProxy config: add the panel route ----------------------------------
if [[ "$ALREADY_CFG" != "1" ]]; then
  # Find the updated template: this repo's copy first, then GitHub raw.
  TPL=""
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for cand in "$HERE/../templates/haproxy.cfg.tpl" "/root/vps-manager-suite/templates/haproxy.cfg.tpl" "/opt/vps-manager-suite/templates/haproxy.cfg.tpl"; do
    [[ -f "$cand" ]] && grep -q "panel_backend" "$cand" && { TPL="$cand"; break; }
  done
  if [[ -z "$TPL" ]]; then
    say "Downloading the updated HAProxy template from GitHub..."
    if curl -fsSL "$REPO_RAW/templates/haproxy.cfg.tpl" -o /tmp/haproxy.cfg.tpl \
       && grep -q "panel_backend" /tmp/haproxy.cfg.tpl; then
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

# --- 8. Reload HAProxy + verify it is up --------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  systemctl reload haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null || true
  if systemctl is-active --quiet haproxy; then
    ok "HAProxy is active"
  else
    err "HAProxy is NOT active after reload - diagnose: systemctl status haproxy | journalctl -u haproxy -n 30 --no-pager"
    exit 1
  fi
fi

# --- 9. Renewal hook (lineage-aware: panel cert must never overwrite the main cert)
HOOK=/etc/letsencrypt/renewal-hooks/deploy/vps-manager.sh
mkdir -p "$(dirname "$HOOK")" 2>/dev/null || true
cat > "$HOOK" <<'HOOK'
#!/usr/bin/env bash
# VPS Manager Suite - certbot deploy hook (installed by scripts/fix-panel-443.sh)
# RENEWED_LINEAGE points at the renewed cert's live directory.
set -u
SSL_DIR="/etc/vps-manager/ssl"
[[ -n "${RENEWED_LINEAGE:-}" && -s "$RENEWED_LINEAGE/fullchain.pem" ]] || exit 0
mkdir -p "$SSL_DIR"
# The panel subdomain has its own lineage (panel.<domain>). A renewal of
# it must land in the panel pair, NOT overwrite the main-domain pair -
# the panel cert is only valid for panel.<domain>.
case "$(basename "$RENEWED_LINEAGE")" in
  panel.*)
    cp "$RENEWED_LINEAGE/fullchain.pem" "$SSL_DIR/panel-fullchain.pem" || true
    cp "$RENEWED_LINEAGE/privkey.pem" "$SSL_DIR/panel-privkey.pem" || true
    chmod 600 "$SSL_DIR/panel-privkey.pem" 2>/dev/null || true
    ;;
  *)
    cp "$RENEWED_LINEAGE/fullchain.pem" "$SSL_DIR/fullchain.pem" || true
    cp "$RENEWED_LINEAGE/privkey.pem" "$SSL_DIR/privkey.pem" || true
    chmod 600 "$SSL_DIR/privkey.pem" 2>/dev/null || true
    cat "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" > "$SSL_DIR/combined.pem" 2>/dev/null || true
    ;;
esac
cat "$SSL_DIR/fullchain.pem" "$SSL_DIR/privkey.pem" > "$SSL_DIR/haproxy.pem" 2>/dev/null || true
if [[ -s "$SSL_DIR/panel-fullchain.pem" && -s "$SSL_DIR/panel-privkey.pem" ]]; then
  cat "$SSL_DIR/panel-fullchain.pem" "$SSL_DIR/panel-privkey.pem" >> "$SSL_DIR/haproxy.pem" 2>/dev/null || true
fi
chmod 600 "$SSL_DIR/haproxy.pem" 2>/dev/null || true
for s in haproxy xray vps-panel; do systemctl restart "$s" 2>/dev/null || true; done
exit 0
HOOK
chmod +x "$HOOK" 2>/dev/null || true
ok "Cert renewal hook installed (panel lineage handled separately)"

# --- 10. Live tests -------------------------------------------------------------
say "Testing the panel on 443..."
PANEL_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$PANEL_HOST/" 2>/dev/null || echo 000)"
LOGIN_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$PANEL_HOST/login" 2>/dev/null || echo 000)"
MAIN_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null || echo 000)"
VMESS_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$DOMAIN/vmess" 2>/dev/null || echo 000)"
echo "    https://$PANEL_HOST/        -> HTTP $PANEL_CODE (expect 302, the login redirect)"
echo "    https://$PANEL_HOST/login   -> HTTP $LOGIN_CODE (expect 200, the login page)"
echo "    https://$DOMAIN/            -> HTTP $MAIN_CODE (expect 200, unchanged)"
echo "    https://$DOMAIN/vmess       -> HTTP $VMESS_CODE (expect 400, Xray answering - VPN untouched)"
echo
if [[ "$PANEL_CODE" == "302" && "$LOGIN_CODE" == "200" ]]; then
  ok "DONE - the panel is live at https://$PANEL_HOST (port 443, no :9090 needed)."
  echo "    The old address https://$DOMAIN:9090 still works as a fallback."
else
  warn "The panel did not answer as expected on 443 (panel / = $PANEL_CODE, /login = $LOGIN_CODE)."
  echo "    HAProxy is running and the config is valid; check: journalctl -u haproxy -n 30 --no-pager"
  echo "    and confirm the DNS A record panel.$DOMAIN -> $PANEL_IP has propagated (getent hosts $PANEL_HOST)."
  exit 1
fi
