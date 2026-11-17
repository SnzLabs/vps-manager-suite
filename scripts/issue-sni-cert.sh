#!/usr/bin/env bash
# VPS Manager Suite - issue a TLS certificate for one custom SNI domain.
#
# Usage: issue-sni-cert.sh <domain>
#
# Issues a Let's Encrypt certificate for <domain> (the operator must own
# it and point it at this VPS with an A record) and places the combined
# bundle in /etc/vps-manager/ssl/certs/<domain>.pem, where the https_in
# frontend loads it alongside the main haproxy.pem - HAProxy then serves
# this certificate when a client presents that SNI. HAProxy is reloaded
# so the new certificate is served immediately.
#
# If the domain is the main domain, or a certificate already exists and
# is valid, this is a no-op that just reports it. If issuance fails
# (domain does not resolve here, port 80 blocked, rate limit...), it
# prints the certbot reason and exits non-zero; the SNI still routes,
# but clients that verify the certificate will see the main domain's
# cert and may reject the connection.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" 2>/dev/null || true
if ! declare -F issue_sni_cert >/dev/null 2>&1; then
  echo "[ERROR] lib/common.sh (issue_sni_cert) is missing - run vpsupdate first." >&2
  exit 1
fi
DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 <domain>" >&2
  exit 2
fi
issue_sni_cert "$DOMAIN"
