#!/usr/bin/env bash
set -euo pipefail

# Run after setup.sh. Obtains Let's Encrypt cert via webroot, installs renew hook,
# and restarts the service with HTTPS enabled (if systemd unit exists).

NAME="prusaslicer-be"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
ACME_ROOT="/var/www/acme"
ACME_DIR="$ACME_ROOT/.well-known/acme-challenge"
CERTBOT_WEBROOT="$ACME_ROOT"  # certbot writes under $ACME_ROOT/.well-known/acme-challenge

read -rp "Admin email for Let's Encrypt (e.g. you@example.com): " LE_EMAIL
read -rp "Domain name (DNS A/AAAA must point here): " DOMAIN
if [[ -z "${LE_EMAIL}" || -z "${DOMAIN}" ]]; then
  echo "Email and domain are required." >&2
  exit 1
fi

echo "[1/7] Install certbot"
sudo apt update
sudo apt install -y certbot

echo "[2/7] Ensure ACME webroot"
sudo mkdir -p "$ACME_DIR"
sudo chown -R "$USER":"$USER" "$ACME_ROOT"

echo "[3/7] Ensure something serves ACME on :80"
# If nothing listens on :80, start a temporary Bun HTTP server with HTTPS disabled.
if ! ss -ltn '( sport = :80 )' | grep -q LISTEN; then
  echo "No listener on :80 -> starting temporary Bun ACME server"
  (
    cd "$REPO_DIR"
    export HTTPS=""                 # force HTTP-only
    export HTTP_PORT=80
    export PORT=8080
    export ACME_DIR="$ACME_DIR"
    bun run src/index.ts
  ) >/tmp/acme-temp.log 2>&1 &
  TMP_PID=$!
  sleep 2
else
  TMP_PID=""
  echo "Port :80 already served (systemd or other). Using that for ACME."
fi

echo "[4/7] Obtain certificate for $DOMAIN via webroot"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
  echo "Existing certificate found -> skipping issuance"
else
  sudo certbot ce
fi
