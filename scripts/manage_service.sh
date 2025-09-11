#!/usr/bin/env bash
set -euo pipefail

# Usage: bash ./scripts/manage_service.sh
# Checks for systemd or pm2. If service exists → restart. Else → register and start.

NAME="prusaslicer-be"
PORT="${PORT:-8080}"

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
USER_NAME="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
BUN_DIR="${BUN_INSTALL:-$USER_HOME/.bun}"
BUN_BIN="$BUN_DIR/bin/bun"

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
User=%i
WorkingDirectory=REPO_DIR_REPLACED
Environment=PORT=443
Environment=HTTP_PORT=80
Environment=HTTPS=1
Environment=DOMAIN=your.domain.tld
Environment=ACME_DIR=/var/www/acme
Environment=BUN_INSTALL=USER_HOME_REPLACED/.bun
Environment=PATH=USER_HOME_REPLACED/.bun/bin:/usr/local/bin:/usr/bin
ExecStart=USER_HOME_REPLACED/.bun/bin/bun run REPO_DIR_REPLACED/src/index.ts
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

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
  # try to install pm2 if missing
  if ! have_cmd pm2; then
    echo "[service] pm2 not found. Installing via npm..."
    if have_cmd npm; then
      sudo npm i -g pm2
    else
      echo "[service] npm not available. Cannot install pm2 automatically."
      echo "         Either install npm+pm2 or use systemd."
      exit 1
    fi
  fi
  # ensure Bun on PATH for pm2
  export BUN_INSTALL="$BUN_DIR"
  export PATH="$BUN_DIR/bin:$PATH"

  if pm2 list | grep -qE " $NAME \b"; then
    echo "[service] pm2 restart $NAME"
    pm2 restart "$NAME"
  else
    echo "[service] pm2 start"
    pm2 start "$BUN_BIN" --name "$NAME" -- run "$REPO_DIR/src/index.ts"
    pm2 save
    # optional: create startup on boot
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
    # unit file may exist but not listed yet
    if [ -f "/etc/systemd/system/$NAME.service" ]; then
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
