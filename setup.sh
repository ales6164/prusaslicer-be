#!/usr/bin/env bash
set -euo pipefail

# Run as: bash setup.sh
# Assumes Ubuntu 24.04, repo root as CWD, service name "prusaslicer-be"
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

echo "[1/9] apt update"
sudo apt update

echo "[2/9] Install basics: curl, certs, flatpak, certbot"
sudo apt install -y curl ca-certificates flatpak certbot

echo "[3/9] Prepare ACME webroot: $ACME_DIR"
sudo mkdir -p "$ACME_DIR"
sudo chown -R "$USER":"$USER" "$ACME_DIR"

echo "[4/9] Install Bun"
# non-interactive
curl -fsSL https://bun.sh/install | bash
# make bun available now + future shells
if ! command -v bun >/dev/null 2>&1; then
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi
grep -q 'BUN_INSTALL' "$HOME/.bashrc" || {
  echo 'export BUN_INSTALL="$HOME/.bun"' >> "$HOME/.bashrc"
  echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$HOME/.bashrc"
}

echo "[5/9] Install Flathub + PrusaSlicer"
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.prusa3d.PrusaSlicer

echo "[5b/9] Allow PrusaSlicer Flatpak to read host FS"
flatpak override --user --filesystem=host com.prusa3d.PrusaSlicer

echo "[6/9] Verify tools"
bun --version
flatpak run --command=prusa-slicer com.prusa3d.PrusaSlicer --help >/dev/null

echo "[7/9] Install project deps"
bun install

# Write .env for convenience (systemd unit should already set these in manage_service.sh)
echo "[8/9] Write .env"
cat > .env <<EOF
# Convenience env for local runs
HTTPS=1
DOMAIN=${DOMAIN}
ACME_DIR=${ACME_DIR}
PORT=443
HTTP_PORT=80
EOF

# Obtain/renew certs using webroot (requires ACME route reachable on :80)
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
  echo "[9/9] Existing certificate found for ${DOMAIN} -> skipping issuance"
else
  echo "[9/9] Issue Let's Encrypt certificate for ${DOMAIN} via webroot"
  echo "Starting temporary HTTP server to serve ACME on port 80..."
  # Start app in background on HTTP only (no TLS) to serve ACME path
  # Uses ACME_DIR and port 80. Kill after certbot completes.
  (
    export HTTPS=""
    export HTTP_PORT=80
    export ACME_DIR="${ACME_DIR}"
    export PORT=8080
    bun run src/index.ts
  ) &

  TMP_PID=$!
  # Give server time to bind
  sleep 2

  # Request certificate
  sudo certbot certonly \
    --non-interactive --agree-tos -m "${LE_EMAIL}" \
    --webroot -w "${ACME_DIR}" -d "${DOMAIN}"

  # Stop temporary server
  kill ${TMP_PID} >/dev/null 2>&1 || true
  sleep 1
fi

# Install renew hook to restart service after renewal (systemd name: $NAME)
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-${NAME}.sh"
if [[ ! -f "${RENEW_HOOK}" ]]; then
  echo "Installing renew deploy hook -> ${RENEW_HOOK}"
  sudo bash -c "cat > '${RENEW_HOOK}'" <<EOF
#!/usr/bin/env bash
set -e
systemctl restart ${NAME} || true
EOF
  sudo chmod +x "${RENEW_HOOK}"
fi

echo
echo "=== Setup complete ==="
echo "Domain: ${DOMAIN}"
echo "Certs:  ${CERT_DIR}"
echo
echo "Next:"
echo "  1) Ensure your systemd unit exports:"
echo "       HTTPS=1, DOMAIN=${DOMAIN}, ACME_DIR=${ACME_DIR}, PORT=443, HTTP_PORT=80"
echo "     (Your updated scripts/manage_service.sh should already do this.)"
echo "  2) Register/start or restart the service:"
echo "       ./scripts/manage_service.sh      # creates or restarts systemd unit"
echo "       ./scripts/deploy.sh              # git update + restart"
echo
echo "Test:"
echo "  curl -I http://${DOMAIN}/.well-known/acme-challenge/does-not-exist || true"
echo "  curl -k https://${DOMAIN}/"
