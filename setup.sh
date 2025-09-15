#!/usr/bin/env bash
set -euo pipefail

# One-shot bootstrap for mass deployment (HTTP only).
# - Creates dedicated service user
# - Installs Bun (for that user), Flatpak+PrusaSlicer
# - Registers systemd service (HTTP on :80)
# - Idempotent. Safe to re-run.

SERVICE_USER_DEFAULT="slicer"
SERVICE_NAME="prusaslicer-be"
TARGET_DIR="/opt/${SERVICE_NAME}"
BUN_SUBDIR=".bun"

# --- load existing .env for defaults if present ---
ENV_FILE="./.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE" || true
fi
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

echo "=== ${SERVICE_NAME} setup (HTTP only) ==="
SERVICE_USER_INPUT_DEFAULT="${DEF_USER_FROM_ENV:-$SERVICE_USER_DEFAULT}"
SERVICE_USER="$(prompt_default 'Linux user to run the service' "$SERVICE_USER_INPUT_DEFAULT")"

echo "[1/9] apt update + base packages"
sudo apt update
sudo apt install -y curl ca-certificates flatpak git python3 rsync unzip

echo "[2/9] Open firewall for HTTP"
sudo ufw allow 80/tcp || true
sudo ufw --force enable || true

echo "[3/9] Create service user '${SERVICE_USER}' if missing"
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "${SERVICE_USER}"
fi
SERVICE_HOME="$(getent passwd "${SERVICE_USER}" | cut -d: -f6)"
BUN_DIR="${SERVICE_HOME}/${BUN_SUBDIR}"
BUN_BIN="${BUN_DIR}/bin/bun"

echo "[4/9] Sync repo to ${TARGET_DIR}"
sudo mkdir -p "${TARGET_DIR}"
sudo rsync -a --delete ./ "${TARGET_DIR}/"
sudo chown -R "${SERVICE_USER}:${SERVICE_USER}" "${TARGET_DIR}"

echo "[5/9] Install Bun for ${SERVICE_USER}"
sudo -u "${SERVICE_USER}" bash -lc 'command -v bun >/dev/null 2>&1 || (curl -fsSL https://bun.sh/install | bash)'
# Ensure PATH for future logins
if ! sudo -u "${SERVICE_USER}" bash -lc 'grep -q "BUN_INSTALL" ~/.bashrc'; then
  sudo -u "${SERVICE_USER}" bash -lc 'echo "export BUN_INSTALL=\"$HOME/.bun\"" >> ~/.bashrc'
  sudo -u "${SERVICE_USER}" bash -lc 'echo "export PATH=\"$HOME/.bun/bin:\$PATH\"" >> ~/.bashrc'
fi

echo "[6/9] Install Flathub + PrusaSlicer"
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.prusa3d.PrusaSlicer
sudo flatpak override --system --filesystem=host com.prusa3d.PrusaSlicer
flatpak run --command=prusa-slicer com.prusa3d.PrusaSlicer --help >/dev/null || true

echo "[7/9] Install project deps as ${SERVICE_USER}"
sudo -u "${SERVICE_USER}" bash -lc "cd '${TARGET_DIR}' && '${BUN_BIN}' --version && '${BUN_BIN}' install"
sudo chmod +x "${TARGET_DIR}/scripts/"*.sh || true

echo "[8/9] Write .env (HTTP only)"
sudo -u "${SERVICE_USER}" bash -lc "cat > '${TARGET_DIR}/.env' <<EOF
# Managed by setup.sh
SERVICE_USER=${SERVICE_USER}
HTTP_PORT=80
PORT=8080
EOF"

echo "[9/9] Register/start systemd service (HTTP only)"
sudo -E SERVICE_USER="${SERVICE_USER}" env -u BUN_INSTALL bash "${TARGET_DIR}/scripts/manage_service.sh"

# Optional: add 2G swap on small VMs (skip if exists)
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
