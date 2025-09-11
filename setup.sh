#!/usr/bin/env bash
set -euo pipefail

# One-shot bootstrap for mass deployment.
# - Creates dedicated service user
# - Installs Bun (for that user), Flatpak+PrusaSlicer, Certbot
# - Prepares ACME webroot
# - Registers systemd service (HTTP only)
# - Issues Let's Encrypt cert (webroot)
# - Enables HTTPS and restarts service
#
# Run inside your cloned repo directory:
#   bash setup.sh
#
# Idempotent. Safe to re-run.

SERVICE_USER_DEFAULT="slicer"
SERVICE_NAME="prusaslicer-be"
TARGET_DIR="/opt/${SERVICE_NAME}"
ACME_ROOT="/var/www/acme"                         # certbot webroot
ACME_DIR="${ACME_ROOT}/.well-known/acme-challenge" # served by app
BUN_SUBDIR=".bun"

echo "=== ${SERVICE_NAME} setup ==="
read -rp "Domain name (DNS A/AAAA must point here): " DOMAIN
read -rp "Admin email for Let's Encrypt (e.g. you@example.com): " LE_EMAIL
read -rp "Linux user to run the service [${SERVICE_USER_DEFAULT}]: " SERVICE_USER
SERVICE_USER="${SERVICE_USER:-$SERVICE_USER_DEFAULT}"

if [[ -z "${DOMAIN}" || -z "${LE_EMAIL}" ]]; then
  echo "Domain and email are required." >&2
  exit 1
fi

echo "[1/10] apt update + base packages"
sudo apt update
sudo apt install -y curl ca-certificates flatpak certbot git python3 rsync

echo "[2/10] Create service user '${SERVICE_USER}' if missing"
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${SERVICE_USER}"
fi
SERVICE_HOME="$(getent passwd "${SERVICE_USER}" | cut -d: -f6)"
BUN_DIR="${SERVICE_HOME}/${BUN_SUBDIR}"
BUN_BIN="${BUN_DIR}/bin/bun"

echo "[3/10] Sync repo to ${TARGET_DIR}"
sudo mkdir -p "${TARGET_DIR}"
sudo rsync -a --delete ./ "${TARGET_DIR}/"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${TARGET_DIR}"

echo "[4/10] Install Bun for ${SERVICE_USER}"
sudo -u "${SERVICE_USER}" bash -lc 'command -v bun >/dev/null 2>&1 || (curl -fsSL https://bun.sh/install | bash)'
# Ensure PATH for future logins
if ! sudo -u "${SERVICE_USER}" bash -lc 'grep -q "BUN_INSTALL" ~/.bashrc'; then
  sudo -u "${SERVICE_USER}" bash -lc 'echo "export BUN_INSTALL=\"$HOME/.bun\"" >> ~/.bashrc'
  sudo -u "${SERVICE_USER}" bash -lc 'echo "export PATH=\"$HOME/.bun/bin:\$PATH\"" >> ~/.bashrc'
fi

echo "[5/10] Install Flathub + PrusaSlicer"
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.prusa3d.PrusaSlicer
# Host FS access for headless CLI
sudo flatpak override --system --filesystem=host com.prusa3d.PrusaSlicer

echo "[6/10] Prepare ACME webroot"
sudo mkdir -p "${ACME_DIR}"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${ACME_ROOT}"
sudo chmod -R a+rx "${ACME_ROOT}"

echo "[7/10] Install project deps as ${SERVICE_USER}"
sudo -u "${SERVICE_USER}" bash -lc "cd '${TARGET_DIR}' && ${BUN_BIN} --version && ${BUN_BIN} install"
sudo chmod +x "${TARGET_DIR}/scripts/"*.sh

echo "[8/10] Write .env (HTTP first, HTTPS off)"
sudo -u "${SERVICE_USER}" bash -lc "cat > '${TARGET_DIR}/.env' <<EOF
# Managed by setup.sh
SERVICE_USER=${SERVICE_USER}
DOMAIN=${DOMAIN}
ACME_DIR=${ACME_DIR}
HTTP_PORT=80
PORT=8080
HTTPS=
EOF"

echo "[9/10] Register/start systemd service (HTTP only)"
# Recreate unit via manager; it reads .env and embeds EnvironmentFile.
sudo -E SERVICE_USER="${SERVICE_USER}" bash "${TARGET_DIR}/scripts/manage_service.sh"

echo "[10/10] Obtain Let's Encrypt certificate via webroot"
# Ensure something serves /.well-known on :80 — the service is already running on :80.
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
  echo "Certificate already present, skipping issuance."
else
  sudo certbot certonly \
    --non-interactive --agree-tos -m "${LE_EMAIL}" \
    --webroot -w "${ACME_ROOT}" -d "${DOMAIN}"
fi

echo "[10b] Install renew hook to restart service"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-${SERVICE_NAME}.sh"
if [[ ! -f "${RENEW_HOOK}" ]]; then
  sudo bash -c "cat > '${RENEW_HOOK}'" <<EOF
#!/usr/bin/env bash
set -e
systemctl restart ${SERVICE_NAME} || true
EOF
  sudo chmod +x "${RENEW_HOOK}"
fi

echo "[10c] Switch to HTTPS and restart"
sudo -u "${SERVICE_USER}" bash -lc "cat > '${TARGET_DIR}/.env' <<EOF
# Managed by setup.sh
SERVICE_USER=${SERVICE_USER}
DOMAIN=${DOMAIN}
ACME_DIR=${ACME_DIR}
HTTP_PORT=80
PORT=443
HTTPS=1
EOF"
sudo -E SERVICE_USER="${SERVICE_USER}" bash "${TARGET_DIR}/scripts/manage_service.sh"

echo
echo "=== Done ==="
echo "Repo:  ${TARGET_DIR}"
echo "User:  ${SERVICE_USER}"
echo "Certs: ${CERT_DIR}"
echo "HTTP->HTTPS: curl -I http://${DOMAIN}/"
echo "HTTPS alive:  curl -I https://${DOMAIN}/"
