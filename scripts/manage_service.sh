#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash scripts/manage_service.sh
# Behavior:
#   - Load .env from repo root if present (export all vars).
#   - If systemd unit exists -> restart it.
#   - Else create a unit with resolved paths and EnvironmentFile, enable and start.
#   - Fallback to pm2 if systemd is unavailable.

NAME="prusaslicer-be"

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
ENV_FILE="${REPO_DIR}/.env"

# Load .env if present (exported). Comments and empty lines ok.
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
BUN_DIR="${BUN_INSTALL:-$USER_HOME/.bun}"
BUN_BIN="$BUN_DIR/bin/bun"

# Allow CLI overrides to beat .env
HTTPS="${HTTPS:-${HTTPS:-}}"
DOMAIN="${DOMAIN:-${DOMAIN:-}}"
ACME_DIR="${ACME_DIR:-${ACME_DIR:-/var/www/acme/.well-known/acme-challenge}}"
HTTP_PORT="${HTTP_PORT:-${HTTP_PORT:-80}}"
PORT="${PORT:-${PORT:-8080}}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

restart_systemd() {
  sudo systemctl daemon-reload
  sudo systemctl restart "$NAME"
  sudo systemctl status "$NAME" --no-pager -l || true
}

register_systemd() {
  echo "[service] registering systemd unit"
  UNIT_PATH="/etc/systemd/system/$NAME.service"
  TMP_UNIT="$(mktemp)"

  cat >"$TMP_UNIT" <<EOF
[Unit]
Description=PrusaSlicer G-code microservice (Bun)
After=network.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${REPO_DIR}
# Load dynamic env from repo .env if present
EnvironmentFile=-${ENV_FILE}
# Hard env fallbacks (used if .env unset)
Environment=HTTPS=${HTTPS}
Environment=DOMAIN=${DOMAIN}
Environment=ACME_DIR=${ACME_DIR}
Environment=HTTP_PORT=${HTTP_PORT}
Environment=PORT=${PORT}
Environment=BUN_INSTALL=${BUN_DIR}
Environment=PATH=${BUN_DIR}/bin:/usr/local/bin:/usr/bin
ExecStart=${BUN_BIN} run ${REPO_DIR}/src/index.ts
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  sudo mv "$TMP_UNIT" "$UNIT_PATH"
  sudo systemctl daemon-reload
  sudo systemctl enable "$NAME"
  sudo systemctl start "$NAME"
  sudo systemctl status "$NAME" --no-pager -l || true
}

pm2_start() {
  if ! have_cmd pm2; then
    echo "[service] pm2 not found. Installing via npm..."
    if have_cmd npm; then
      sudo npm i -g pm2
    else
      echo "[service] npm not available. Install npm+pm2 or use systemd."
      exit 1
    fi
  fi
  export BUN_INSTALL="$BUN_DIR"
  export PATH="$BUN_DIR/bin:$PATH"

  if pm2 list | grep -qE " $NAME\b"; then
    echo "[service] pm2 restart $NAME"
    pm2 restart "$NAME"
  else
    echo "[service] pm2 start"
    pm2 start "$BUN_BIN" --name "$NAME" -- run "$REPO_DIR/src/index.ts"
    pm2 save
    pm2 startup systemd -u "$USER_NAME" --hp "$USER_HOME" >/dev/null || true
  fi
}

main() {
  if have_cmd systemctl; then
    if systemctl list-units --type=service --all | grep -q "^$NAME.service"; then
      echo "[service] systemd unit exists → restart"
      restart_systemd
      exit 0
    fi
    if [[ -f "/etc/systemd/system/$NAME.service" ]]; then
      echo "[service] systemd unit file found → restart"
      restart_systemd
      exit 0
    fi
    register_systemd
    exit 0
  fi
  echo "[service] systemd not available → using pm2"
  pm2_start
}

main "$@"
