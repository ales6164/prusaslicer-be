#!/usr/bin/env bash
set -euo pipefail

NAME="prusaslicer-be"

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-units --type=service --all | grep -q "^$NAME.service"; then
    echo "[stop] stopping systemd service $NAME"
    sudo systemctl stop "$NAME"
    exit 0
  fi
fi

if command -v pm2 >/dev/null 2>&1; then
  if pm2 list | grep -qE " $NAME \b"; then
    echo "[stop] stopping pm2 process $NAME"
    pm2 stop "$NAME" || true
    pm2 delete "$NAME" || true
    exit 0
  fi
fi

echo "[stop] service $NAME not found (systemd or pm2)"
