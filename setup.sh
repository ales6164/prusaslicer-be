#!/usr/bin/env bash
set -euo pipefail

# Run as: bash setup.sh  (project root)
# Requires: scripts/manage_service.sh already present and configured for :80 and :443

NAME="prusaslicer-be"
REPO_DIR="$(pwd)"
ACME_DIR="/var/www/acme"

echo "=== PrusaSlicer G-code service setup ==="
read -rp "Admin email for Let's Encrypt (e.g. you@example.com): " LE_EMAIL
read -rp "Domain name (A/AAAA DNS must already point here): " DOMAIN
if [[ -z "${LE_EMAIL}" || -z "${DOMAIN}" ]]; then
  echo "Email and domain are required." >&2
  exit 1
fi

echo "[1/10] apt update"
sudo apt update

echo "[2/10] Install packages"
sudo apt install -y curl ca-certificates flatpak certbot python3

echo "[3/10] Prepare ACME webroot: $ACME_DIR"
sudo mkdir -p "$ACME_DIR/.well-known/acme-challenge"
sudo chown -R "$USER":"$USER" "$ACME_DIR"

echo "[4/10] Install Bun"
curl -fsSL https://bun.sh/install | bash
if ! command -v bun >/dev/null 2>&1; then
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi
grep -q 'BUN_INSTALL' "$HOME/.bashrc" || {
  echo 'export BUN_INSTALL="$HOME/.bun"' >> "$HOME/.bashrc"
  echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$HOME/.bashrc"
}

echo "[5/10] Install Flathub + PrusaSlicer"
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.prusa3d.PrusaSlicer
echo "[5b/10] Allow PrusaSlicer Flatpak to read host FS"
flatpak override --user --filesystem=host com.prusa3d.PrusaSlicer

echo "[6/10] Verify tools"
bun --version
flatpak run --command=prusa-slicer com.prusa3d.PrusaSlicer --help >/dev/null

echo "[7/10] Install project deps"
bun install

echo "[8/10] Bootstrap ACME: start temporary HTTP server on :80"
# Serve ACME_DIR directly to satisfy HTTP-01 while we don't have certs yet.
# Using python to avoid needing CAP_NET_BIND_SERVICE for bun.
sudo nohup python3 -m http.server 80 --directory "$ACME_DIR" \
  >/tmp/acme-bootstrap.log 2>&1 &
BOOT_PID=$!
sleep 2

# Quick readiness probe
if ! curl -fsS "http://127.0.0.1/.well-known/acme-challenge/" >/dev/null 2>&1; then
  echo "Temporary ACME server not reachable on :80" >&2
  sudo kill "$BOOT_PID" || true
  exit 1
fi

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
  echo "[8b/10] Existing certificate found for ${DOMAIN} -> skipping issuance"
else
  echo "[9/10] Issue Let's Encrypt certificate for ${DOMAIN} via webroot"
  sudo certbot certonly \
    --non-interactive --agree-tos -m "${LE_EMAIL}" \
    --webroot -w "${ACME_DIR}" -d "${DOMAIN}"
fi

echo "[9b/10] Stop temporary ACME server"
sudo kill "$BOOT_PID" || true
sleep 1

# Renew hook to restart service on successful renewal
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-${NAME}.sh"
if [[ ! -f "${RENEW_HOOK}" ]]; then
  echo "[9c/10] Install renew hook -> ${RENEW_HOOK}"
  sudo bash -c "cat > '${RENEW_HOOK}'" <<EOF
#!/usr/bin/env bash
set -e
systemctl restart ${NAME} || true
EOF
  sudo chmod +x "${RENEW_HOOK}"
fi

echo "[9d/10] Write .env for local runs"
cat > .env <<EOF
HTTPS=1
DOMAIN=${DOMAIN}
ACME_DIR=${ACME_DIR}
PORT=443
HTTP_PORT=80
EOF

echo "[10/10] Register and start service via systemd"
# Your scripts/manage_service.sh should embed:
#   Environment=HTTPS=1
#   Environment=DOMAIN=${DOMAIN}
#   Environment=ACME_DIR=${ACME_DIR}
#   Environment=PORT=443
#   Environment=HTTP_PORT=80
#   AmbientCapabilities=CAP_NET_BIND_SERVICE
#   CapabilityBoundingSet=CAP_NET_BIND_SERVICE
./scripts/manage_service.sh

echo
echo "=== Setup complete ==="
echo "Domain: ${DOMAIN}"
echo "Certs:  ${CERT_DIR}"
echo
echo "Test ACME (HTTP):  curl -I http://${DOMAIN}/.well-known/acme-challenge/does-not-exist || true"
echo "Test HTTPS:        curl -I https://${DOMAIN}/"
echo "Update + restart:  ./scripts/deploy.sh"
