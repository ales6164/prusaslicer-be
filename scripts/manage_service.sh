#!/usr/bin/env bash
set -euo pipefail

NAME="prusaslicer-be"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
ENV_FILE="${REPO_DIR}/.env"

[[ -f "$ENV_FILE" ]] && { set -a; # shellcheck disable=SC1090
source "$ENV_FILE"; set +a; }

SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$USER}}"
[[ "$SERVICE_USER" = "root" ]] && { echo "Refusing to install as root"; exit 1; }

SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
HTTP_PORT="${HTTP_PORT:-80}"
PORT="${PORT:-8080}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_systemd_unit() {
  local UNIT="/etc/systemd/system/${NAME}.service"

  # bun binary path (installed by setup to /usr/local/bin)
  local BUN_BIN="/usr/local/bin/bun"

  local TMP; TMP="$(mktemp)"
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

# Pre-flight checks with explicit errors
ExecStartPre=/bin/bash -lc 'test -x ${BUN_BIN} || { echo "bun missing at ${BUN_BIN}"; exit 1; }'
ExecStartPre=/bin/bash -lc 'test -r ${REPO_DIR}/src/index.ts || { echo "index.ts missing"; exit 1; }'

# Direct exec. No shell wrapper needed.
ExecStart=${BUN_BIN} run ${REPO_DIR}/src/index.ts
Restart=on-failure
RestartSec=2
TimeoutStopSec=15
KillSignal=SIGINT
NoNewPrivileges=true

# Hardening
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${REPO_DIR}
PrivateTmp=true
ProtectHostname=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
SystemCallFilter=@system-service
LockPersonality=true

# We granted cap_net_bind_service to bun, so no caps needed here.

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
  echo "systemd not available. Install systemd or manage with pm2 manually." >&2
  exit 1
}

main() {
  if have_cmd systemctl; then
    ensure_systemd_unit
    systemd_restart
    exit 0
  fi
  pm2_start
}

main "$@"
