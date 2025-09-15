#!/usr/bin/env bash
set -euo pipefail

# prusaslicer-be: install/repair systemd unit with XDG dirs (no home writes)

NAME="prusaslicer-be"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
ENV_FILE="${REPO_DIR}/.env"

# --- load .env (SERVICE_USER, PORTs) ---
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$USER}}"
[[ "$SERVICE_USER" = "root" ]] && { echo "Refusing to install as root"; exit 1; }
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
HTTP_PORT="${HTTP_PORT:-80}"
PORT="${PORT:-8080}"

# bun at /usr/local/bin with cap_net_bind_service
ensure_bun() {
  if ! command -v bun >/dev/null 2>&1; then
    sudo -u "$SERVICE_USER" -H bash -lc 'curl -fsSL https://bun.sh/install | bash'
  fi
  local USER_BUN="${SERVICE_HOME}/.bun/bin/bun"
  if [[ -x "$USER_BUN" ]]; then
    sudo install -m 0755 "$USER_BUN" /usr/local/bin/bun
  fi
  if command -v setcap >/dev/null 2>&1; then
    sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/bun || true
  fi
}

# XDG dirs inside repo (writable under hardening)
prep_xdg() {
  sudo -u "$SERVICE_USER" -H mkdir -p \
    "${REPO_DIR}/.xdg/cache" \
    "${REPO_DIR}/.xdg/config" \
    "${REPO_DIR}/.xdg/data" \
    "${REPO_DIR}/.xdg/state"
  sudo chown -R "$SERVICE_USER:$SERVICE_USER" "${REPO_DIR}/.xdg"
}

write_unit() {
  local UNIT="/etc/systemd/system/${NAME}.service"
  local BUN_BIN="/usr/local/bin/bun"

  # Pre-calc ReadWritePaths entries
  local RW="${REPO_DIR}
${REPO_DIR}/.xdg
${REPO_DIR}/.xdg/cache
${REPO_DIR}/.xdg/config
${REPO_DIR}/.xdg/data
${REPO_DIR}/.xdg/state"

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
Environment=XDG_CACHE_HOME=${REPO_DIR}/.xdg/cache
Environment=XDG_CONFIG_HOME=${REPO_DIR}/.xdg/config
Environment=XDG_DATA_HOME=${REPO_DIR}/.xdg/data
Environment=XDG_STATE_HOME=${REPO_DIR}/.xdg/state

# Pre-flight checks
ExecStartPre=/bin/bash -lc 'test -x ${BUN_BIN} || { echo "bun missing at ${BUN_BIN}"; exit 1; }'
ExecStartPre=/bin/bash -lc 'test -r ${REPO_DIR}/src/index.ts || { echo "index.ts missing"; exit 1; }'

# Run bun directly
ExecStart=${BUN_BIN} run ${REPO_DIR}/src/index.ts

Restart=on-failure
RestartSec=2
TimeoutStopSec=15
KillSignal=SIGINT
NoNewPrivileges=true

# Hardening (home read-only; only repo paths are writable)
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$(echo "${RW}" | tr '\n' ' ')
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

[Install]
WantedBy=multi-user.target
EOF

  sudo mv "$TMP" "$UNIT"
  sudo systemctl daemon-reload
  sudo systemctl enable "$NAME"
}

restart_service() {
  sudo systemctl restart "$NAME"
  sudo systemctl status "$NAME" --no-pager -l || true
}

main() {
  ensure_bun
  prep_xdg
  write_unit
  restart_service
}

main "$@"
