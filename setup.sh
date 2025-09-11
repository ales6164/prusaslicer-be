#!/usr/bin/env bash
set -euo pipefail

# One-shot bootstrap for mass deployment.
# - Creates dedicated service user
# - Installs Bun (for that user), Flatpak+PrusaSlicer
# - Prepares ACME webroot
# - Registers systemd service (HTTP first)
# - Opens firewall, enables certbot.timer
# - Issues Let's Encrypt cert (webroot; guarantees :80 listener)
# - Enables HTTPS and restarts service
# Idempotent. Safe to re-run.

SERVICE_USER_DEFAULT="slicer"
SERVICE_NAME="prusaslicer-be"
TARGET_DIR="/opt/${SERVICE_NAME}"
ACME_ROOT="/var/www/acme"                           # certbot webroot
ACME_DIR="${ACME_ROOT}/.well-known/acme-challenge"  # served by app
BUN_SUBDIR=".bun"

# --- load existing .env for defaults if present ---
ENV_FILE="./.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
fi
DEF_DOMAIN="${DOMAIN:-}"
DEF_EMAIL="${CERTBOT_EMAIL:-${LE_EMAIL:-}}"
DEF_USER_FROM_ENV="${SERVICE_USER:-}"

prompt_default() {
  local label="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then
    read -rp "$label [$def]: " ans || true
    echo "${ans:-$def}"
  else
    read -rp "$label: " ans
    echo "$ans"
  fi
}

echo "=== ${SERVICE_NAME} setup ==="
DOMAIN="$(prompt_default 'Domain name (DNS A/AAAA must point here)' "$DEF_DOMAIN")"
CERTBOT_EMAIL="$(prompt_default 'Admin email for Let'\''s Encrypt' "$DEF_EMAIL")"
SERVICE_USER_INPUT_DEFAULT="${DEF_USER_FROM_ENV:-$SERVICE_USER_DEFAULT}"
SERVICE_USER="$(prompt_default 'Linux user to run the service' "$SERVICE_USER_INPUT_DEFAULT")"

if [[ -z "${DOMAIN}" || -z "${CERTBOT_EMAIL}" ]]; then
  echo "Domain and email are required." >&2
  exit 1
fi

echo "[1/12] apt update + base packages"
sudo apt update
sudo apt install -y curl ca-certificates flatpak certbot git python3 rsync unzip

echo "[2/12] Open firewall and enable certbot.timer"
sudo ufw allow 80/tcp || true
sudo ufw allow 443/tcp || true
sudo ufw --force enable || true
sudo systemctl enable --now certbot.timer || true

echo "[3/12] Create service user '${SERVICE_USER}' if missing"
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${SERVICE_USER}"
fi
SERVICE_HOME="$(getent passwd "${SERVICE_USER}" | cut -d: -f6)"
BUN_DIR="${SERVICE_HOME}/${BUN_SUBDIR}"
BUN_BIN="${BUN_DIR}/bin/bun"

echo "[4/12] Sync repo to ${TARGET_DIR}"
sudo mkdir -p "${TARGET_DIR}"
sudo rsync -a --delete ./ "${TARGET_DIR}/"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${TARGET_DIR}"

echo "[5/12] Install Bun for ${SERVICE_USER}"
sudo -u "${SERVICE_USER}" bash -lc 'command -v bun >/dev/null 2>&1 || (curl -fsSL https://bun.sh/install | bash)'
# Ensure PATH for future logins
if ! sudo -u "${SERVICE_USER}" bash -lc 'grep -q "BUN_INSTALL" ~/.bashrc'; then
  sudo -u "${SERVICE_USER}" bash -lc 'echo "export BUN_INSTALL=\"$HOME/.bun\"" >> ~/.bashrc'
  sudo -u "${SERVICE_USER}" bash -lc 'echo "export PATH=\"$HOME/.bun/bin:\$PATH\"" >> ~/.bashrc'
fi

echo "[6/12] Install Flathub + PrusaSlicer"
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.prusa3d.PrusaSlicer
# System-wide FS access for headless CLI
sudo flatpak override --system --filesystem=host com.prusa3d.PrusaSlicer
# Warm up CLI once
flatpak run --command=prusa-slicer com.prusa3d.PrusaSlicer --help >/dev/null || true

echo "[7/12] Prepare ACME webroot"
sudo mkdir -p "${ACME_DIR}"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${ACME_ROOT}"
sudo chmod -R a+rx "${ACME_ROOT}"

echo "[8/12] Install project deps as ${SERVICE_USER}"
sudo -u "${SERVICE_USER}" bash -lc "cd '${TARGET_DIR}' && '${BUN_BIN}' --version && '${BUN_BIN}' install"
sudo chmod +x "${TARGET_DIR}/scripts/"*.sh || true

echo "[9/12] Write .env (HTTP first, HTTPS off; also store CERTBOT_EMAIL)"
sudo -u "${SERVICE_USER}" bash -lc "cat > '${TARGET_DIR}/.env' <<EOF
# Managed by setup.sh
SERVICE_USER=${SERVICE_USER}
DOMAIN=${DOMAIN}
CERTBOT_EMAIL=${CERTBOT_EMAIL}
ACME_DIR=${ACME_DIR}
HTTP_PORT=80
PORT=8080
HTTPS=
EOF"

echo "[10/12] Register/start systemd service (HTTP only)"
# Ensure manager runs without inheriting root's BUN_INSTALL
sudo -E SERVICE_USER="${SERVICE_USER}" env -u BUN_INSTALL bash "${TARGET_DIR}/scripts/manage_service.sh"

echo "[11/12] Obtain Let's Encrypt certificate via webroot (guarantee :80 listener)"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
TMP_PID=""
# If nothing on :80, start a temporary Python server to serve ${ACME_ROOT}
if ! ss -ltn '( sport = :80 )' | grep -q LISTEN; then
  echo "No listener on :80 -> starting temporary ACME server"
  sudo nohup python3 -m http.server 80 --directory "${ACME_ROOT}" >/tmp/acme-boot.log 2>&1 &
  TMP_PID=$!
  sleep 2
fi
if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
  echo "Certificate already present, skipping issuance."
else
  sudo certbot certonly \
    --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" \
    --webroot -w "${ACME_ROOT}" -d "${DOMAIN}"
fi
# Stop temp server if it was started
if [[ -n "${TMP_PID}" ]]; then
  sudo kill "${TMP_PID}" || true
  sleep 1
fi

echo "[11b/12] Install renew hook to restart service"
RENEW_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-${SERVICE_NAME}.sh"
if [[ ! -f "${RENEW_HOOK}" ]]; then
  sudo bash -c "cat > '${RENEW_HOOK}'" <<EOF
#!/usr/bin/env bash
set -e
systemctl restart ${SERVICE_NAME} || true
EOF
  sudo chmod +x "${RENEW_HOOK}"
fi

echo "[11c/12] Optional: add 2G swap on small VMs (skip if exists)"
if ! sudo swapon --show | grep -q '^/swapfile'; then
  sudo fallocate -l 2G /swapfile || true
  sudo chmod 600 /swapfile || true
  sudo mkswap /swapfile || true
  sudo swapon /swapfile || true
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

echo "[12/12] Switch to HTTPS and restart"
sudo -u "${SERVICE_USER}" bash -lc "cat > '${TARGET_DIR}/.env' <<EOF
# Managed by setup.sh
SERVICE_USER=${SERVICE_USER}
DOMAIN=${DOMAIN}
CERTBOT_EMAIL=${CERTBOT_EMAIL}
ACME_DIR=${ACME_DIR}
HTTP_PORT=80
PORT=443
HTTPS=1
EOF"
sudo -E SERVICE_USER="${SERVICE_USER}" env -u BUN_INSTALL bash "${TARGET_DIR}/scripts/manage_service.sh"

echo
echo "=== Done ==="
echo "Repo:  ${TARGET_DIR}"
echo "User:  ${SERVICE_USER}"
echo "Certs: ${CERT_DIR}"
echo "HTTP->HTTPS: curl -I http://${DOMAIN}/"
echo "HTTPS alive:  curl -I https://${DOMAIN}/"
