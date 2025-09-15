#!/usr/bin/env bash
set -euo pipefail

NAME="prusaslicer-be"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
ENV_FILE="${REPO_DIR}/.env"

# Load .env first so SERVICE_USER from .env wins
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Service user (do NOT default to root’s env)
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$USER}}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"

# Always compute Bun path from SERVICE_USER. Ignore ambient BUN_INSTALL.
BUN_DIR="${SERVICE_HOME}/.bun"
BUN_BIN="${BUN_DIR}/bin/bun"

HTTP_PORT="${HTTP_PORT:-80}"
PORT="${PORT:-8080}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_systemd_unit() {
  local UNIT="/etc/systemd/system/${NAME}.service"

  local HARDENING=""
  if [[ "$SERVICE_USER" != "root" ]]; then
    HARDENING=$'ProtectSystem=full\nProtectHome=true\nPrivateTmp=true'
  fi

  local TMP
  TMP="$(mktemp)"
  cat >"$TMP" <<EOF
[Unit]
Description=PrusaSlicer G-code microservice (Bun)
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${REPO_DIR}
EnvironmentFile=-${ENV_FILE}
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
${HARDENING}

[Install]
WantedBy=multi-user.target
EOF
  sudo mv "$TMP" "$UNIT"
  sudo systemctl daemon-reload
  sudo systemctl enable "$NAME"
}

systemd_restart() {
  sudo systemctl restart "$NAME"
  sudo systemctl status "$NAME" --no-pager -l || true
}

pm2_start() {
  if ! have_cmd pm2; then
    if have_cmd npm; then
      sudo npm i -g pm2
    else
      echo "npm missing. Install npm+pm2 or use systemd." >&2
      exit 1
    fi
  fi
  export PATH="${BUN_DIR}/bin:$PATH"
  if pm2 list | grep -qE " $NAME\b"; then
    pm2 restart "$NAME"
  else
    pm2 start "$BUN_BIN" --name "$NAME" -- run "$REPO_DIR/src/index.ts"
    pm2 save
    pm2 startup systemd -u "$SERVICE_USER" --hp "$SERVICE_HOME" >/dev/null || true
  fi
}

main() {
  if have_cmd systemctl; then
    ensure_systemd_unit
    systemd_restart
    exit 0
  fi
  echo "systemd not available. Falling back to pm2."
  pm2_start
}

main "$@"
