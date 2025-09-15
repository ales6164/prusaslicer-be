#!/usr/bin/env bash
set -euo pipefail

# Non-interactive bootstrap (HTTP only).
# - Creates service user
# - Installs Bun to /usr/local/bin + grants :80 bind
# - Installs Flatpak+PrusaSlicer
# - Syncs repo to /opt/<service>
# - Registers hardened systemd unit
# Idempotent.

export DEBIAN_FRONTEND=noninteractive

SERVICE_USER_DEFAULT="slicer"
SERVICE_NAME="prusaslicer-be"
TARGET_DIR="/opt/${SERVICE_NAME}"

# load defaults if present
ENV_FILE="./.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true

prompt_default() {
  local label="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then read -rp "$label [$def]: " ans || true; echo "${ans:-$def}"
  else read -rp "$label: " ans; echo "$ans"; fi
}

echo "=== ${SERVICE_NAME} setup (HTTP only) ==="
SERVICE_USER="$(prompt_default 'Linux user to run the service' "${SERVICE_USER:-$SERVICE_USER_DEFAULT}")"
SERVICE_HOME="$(getent passwd "${SERVICE_USER}" | cut -d: -f6 || true)"
if [[ -z "${SERVICE_HOME}" ]]; then
  sudo useradd -m -s /bin/bash "${SERVICE_USER}"
  SERVICE_HOME="$(getent passwd "${SERVICE_USER}" | cut -d: -f6)"
fi

echo "[1/9] apt update + base packages"
sudo apt update
sudo apt install -y curl ca-certificates flatpak git python3 rsync unzip libcap2-bin

echo "[2/9] Open firewall for HTTP"
if sudo ufw status >/dev/null 2>&1; then
  sudo ufw allow 80/tcp || true
  sudo ufw --force enable || true
fi

echo "[3/9] Sync repo to ${TARGET_DIR}"
sudo mkdir -p "${TARGET_DIR}"
sudo rsync -a --delete ./ "${TARGET_DIR}/"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${TARGET_DIR}"

echo "[4/9] Install Bun and expose as /usr/local/bin/bun"
if ! command -v bun >/dev/null 2>&1; then
  sudo -u "${SERVICE_USER}" bash -lc 'command -v bun >/dev/null 2>&1 || (curl -fsSL https://bun.sh/install | bash)'
fi
# prefer the per-user bun as source
USER_BUN="${SERVICE_HOME}/.bun/bin/bun"
if [[ -x "$USER_BUN" ]]; then
  sudo install -m 0755 "$USER_BUN" /usr/local/bin/bun
fi
# allow binding :80 without root/caps in unit
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/bun || true

echo "[5/9] Install Flathub + PrusaSlicer"
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.prusa3d.PrusaSlicer
sudo flatpak override --system --filesystem=host com.prusa3d.PrusaSlicer
flatpak run --command=prusa-slicer com.prusa3d.PrusaSlicer --help >/dev/null || true

echo "[6/9] Install project deps as ${SERVICE_USER}"
sudo -u "${SERVICE_USER}" bash -lc "cd '${TARGET_DIR}' && bun --version && bun install"
sudo chmod +x "${TARGET_DIR}/scripts/"*.sh || true

echo "[7/9] Write .env (HTTP only)"
sudo -u "${SERVICE_USER}" bash -lc "cat > '${TARGET_DIR}/.env' <<EOF
# Managed by setup.sh
SERVICE_USER=${SERVICE_USER}
HTTP_PORT=80
PORT=8080
EOF"

echo "[8/9] Register/start systemd service (HTTP only)"
sudo -E SERVICE_USER="${SERVICE_USER}" bash "${TARGET_DIR}/scripts/manage_service.sh"

echo "[9/9] Optional: add 2G swap on small VMs"
if ! sudo swapon --show | grep -q '^/swapfile'; then
  sudo fallocate -l 2G /swapfile || true
  sudo chmod 600 /swapfile || true
  sudo mkswap /swapfile || true
  sudo swapon /swapfile || true
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

echo
echo "=== Done (HTTP only) ==="
echo "Repo:  ${TARGET_DIR}"
echo "User:  ${SERVICE_USER}"
echo "HTTP:  curl -I http://localhost/"
