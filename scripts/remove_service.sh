#!/usr/bin/env bash
set -euo pipefail

NAME="prusaslicer-be"

if command -v systemctl >/dev/null 2>&1; then
  if [ -f "/etc/systemd/system/$NAME.service" ]; then
    echo "[remove] disabling + removing systemd service $NAME"
    sudo systemctl stop "$NAME" || true
    sudo systemctl disable "$NAME" || true
    sudo rm -f "/etc/systemd/system/$NAME.service"
    sudo systemctl daemon-reload
    exit 0
  fi
fi

if command -v pm2 >/dev/null 2>&1; then
  if pm2 list | grep -qE " $NAME \b"; then
    echo "[remove] removing pm2 process $NAME"
    pm2 stop "$NAME" || true
    pm2 delete "$NAME" || true
    pm2 save || true
    exit 0
  fi
fi

echo "[remove] service $NAME not found (systemd or pm2)"
