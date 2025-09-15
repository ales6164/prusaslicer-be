#!/usr/bin/env bash
set -euo pipefail

NAME="prusaslicer-be"

# Discover repo and optional SERVICE_USER from .env
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
ENV_FILE="${REPO_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
SERVICE_USER="${SERVICE_USER:-}"

unit_exists() {
  # Prefer systemctl query, fallback to file check
  systemctl status "$NAME" >/dev/null 2>&1 && return 0
  [[ -f "/etc/systemd/system/${NAME}.service" ]] && return 0
  return 1
}

remove_systemd() {
  echo "[remove] systemd: stopping ${NAME}"
  sudo systemctl stop "$NAME" || true
  echo "[remove] systemd: disabling ${NAME}"
  sudo systemctl disable "$NAME" || true
  echo "[remove] systemd: resetting failed state"
  sudo systemctl reset-failed "$NAME" || true

  # Remove unit and any drop-ins
  if [[ -f "/etc/systemd/system/${NAME}.service" ]]; then
    echo "[remove] systemd: removing /etc/systemd/system/${NAME}.service"
    sudo rm -f "/etc/systemd/system/${NAME}.service"
  fi
  if [[ -d "/etc/systemd/system/${NAME}.service.d" ]]; then
    echo "[remove] systemd: removing drop-ins"
    sudo rm -rf "/etc/systemd/system/${NAME}.service.d"
  fi

  echo "[remove] systemd: daemon-reload"
  sudo systemctl daemon-reload
}

pm2_for_user() {
  local u="$1"
  sudo -u "$u" -H bash -lc "command -v pm2 >/dev/null 2>&1" || return 1
  # Exists if describe returns 0
  if sudo -u "$u" -H bash -lc "pm2 describe ${NAME} >/dev/null 2>&1"; then
    echo "[remove] pm2 ($u): stopping/deleting ${NAME}"
    sudo -u "$u" -H bash -lc "pm2 stop ${NAME} || true; pm2 delete ${NAME} || true; pm2 save || true"
    return 0
  fi
  return 1
}

main() {
  local did_any=0

  if command -v systemctl >/dev/null 2>&1 && unit_exists; then
    remove_systemd
    did_any=1
  fi

  # Remove PM2 app for the likely owner
  if [[ -n "$SERVICE_USER" ]]; then
    pm2_for_user "$SERVICE_USER" && did_any=1 || true
  fi

  # Also try current user and common service user names
  pm2_for_user "${SUDO_USER:-$USER}" && did_any=1 || true
  if [[ "${SERVICE_USER:-}" != "slicer" ]]; then
    pm2_for_user "slicer" && did_any=1 || true
  fi

  if [[ "$did_any" -eq 0 ]]; then
    echo "[remove] service ${NAME} not found (systemd or pm2)"
  else
    echo "[remove] done"
  fi
}

main "$@"
