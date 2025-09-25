#!/usr/bin/env bash
# scripts/setup.sh — Fedora setup for prusaslicer-be (verbose, idempotent, auto-reexec on git update)

set -Eeuo pipefail

log()  { printf '[OK] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
err()  { printf '[ERR] %s\n' "$*" >&2; }

# Must run in repo root
[[ -f package.json && -d src ]] || { err "Run from repo root"; exit 1; }

SUDO=""; [[ ${EUID:-$(id -u)} -ne 0 ]] && SUDO=sudo
require_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "missing: $1"; exit 127; }; }
require_cmd dnf; require_cmd curl; require_cmd systemctl; require_cmd bash; require_cmd tee

###############################################################################
# Early git update + auto re-exec (once)
###############################################################################
if [[ -d .git ]]; then
  info "Checking for repo updates"
  set +e
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
  set -e
  if [[ -n "$upstream" ]]; then
    before=$(git rev-parse HEAD)
    git fetch --all --prune || warn "git fetch failed"
    if git merge --ff-only "$upstream"; then
      after=$(git rev-parse HEAD)
      if [[ "$before" != "$after" ]]; then
        info "Repo updated: $before -> $after"
        if [[ "${SETUP_REEXEC:-0}" -lt 1 ]]; then
          info "Re-executing updated setup.sh"
          export SETUP_REEXEC=$(( ${SETUP_REEXEC:-0} + 1 ))
          exec bash "$0" "$@"
        else
          warn "Already re-executed once; continue"
        fi
      else
        log "Repo already up to date"
      fi
    else
      warn "Fast-forward merge not possible; manual resolution needed"
      exit 1
    fi
  else
    warn "No upstream tracking branch; skipping git pull"
  fi
else
  warn "Not a git repo; skipping git pull"
fi

# Ensure persistent journald
if [[ ! -d /var/log/journal ]]; then
  info "Enable persistent journald"
  $SUDO mkdir -p /var/log/journal
  $SUDO systemctl restart systemd-journald || true
fi

dnf_install_or_update(){
  local pkg="$1"
  if rpm -q "$pkg" >/dev/null 2>&1; then
    info "Updating $pkg"
    $SUDO dnf upgrade --refresh -y "$pkg" || warn "Already latest: $pkg"
  else
    info "Installing $pkg"
    $SUDO dnf install -y "$pkg"
  fi
  rpm -q "$pkg" >/dev/null || { err "$pkg not installed"; exit 1; }
  log "$pkg ready"
}

# Packages
dnf_install_or_update prusa-slicer
dnf_install_or_update unzip
dnf_install_or_update git
dnf_install_or_update policycoreutils-python-utils || true

# Bun install/update -> place in /usr/local/bin for systemd
install_or_update_bun(){
  local user_bun="$HOME/.bun/bin/bun"
  local sys_bun="/usr/local/bin/bun"

  if ! command -v bun >/dev/null 2>&1 && [[ ! -x "$user_bun" ]]; then
    info "Installing Bun (user)"
    curl -fsSL https://bun.sh/install | bash
  else
    info "Bun present; upgrading if possible"
    (command -v bun >/dev/null && bun upgrade) || true
  fi

  [[ -x "$user_bun" ]] || { err "Bun not found at $user_bun"; exit 1; }
  "$user_bun" --version >/dev/null

  if [[ ! -x "$sys_bun" ]] || ! cmp -s "$user_bun" "$sys_bun"; then
    info "Copy bun -> $sys_bun"
    $SUDO cp "$user_bun" "$sys_bun"
    $SUDO chown root:root "$sys_bun"
    $SUDO chmod 0755 "$sys_bun"
    command -v restorecon >/dev/null 2>&1 && $SUDO restorecon -v "$sys_bun" || true
  fi

  "$sys_bun" --version >/dev/null || { err "System bun not runnable"; exit 1; }
  log "Bun ready at $sys_bun"
  echo "$sys_bun"
}

BUN_BIN="$(install_or_update_bun)"

# Deps
info "bun install"
"$BUN_BIN" install
log "Dependencies installed"

# Preflight
info "Preflight run: $BUN_BIN run src/server.ts"
set +e
( setsid bash -c "exec $BUN_BIN run src/server.ts" ) &
pid=$!
sleep 5
if ps -p "$pid" >/dev/null 2>&1; then
  kill "$pid" 2>/dev/null || true; sleep 1; kill -9 "$pid" 2>/dev/null || true
else
  warn "Preflight not running after 5s (may exit quickly). Continuing."
fi
set -e

# systemd unit
SERVICE_NAME="prusaslicer-be.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
WORKDIR="$(pwd)"

read -r -d '' UNIT <<EOF
[Unit]
Description=prusaslicer-be Bun backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
WorkingDirectory=${WORKDIR}
ExecStart=${BUN_BIN} run src/server.ts
Restart=on-failure
RestartSec=3
Environment=HOME=${HOME}
Environment=NODE_ENV=production
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

StandardOutput=journal
StandardError=journal
SyslogIdentifier=prusaslicer-be

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
LockPersonality=true
MemoryDenyWriteExecute=false

[Install]
WantedBy=multi-user.target
EOF

info "Writing unit -> $SERVICE_PATH"
printf "%s\n" "$UNIT" | $SUDO tee "$SERVICE_PATH" >/dev/null
$SUDO systemd-analyze verify "$SERVICE_PATH" || true
$SUDO systemctl daemon-reload
$SUDO systemctl enable "$SERVICE_NAME"

# Low-port capability if non-root + PORT<1024
PORT_VALUE="${PORT:-}"
if [[ -f .env ]]; then
  # shellcheck disable=SC2046
  export $(grep -E '^(PORT)=' .env | xargs -d $'\n' -r)
  PORT_VALUE="${PORT:-$PORT_VALUE}"
fi
if [[ "${PORT_VALUE:-}" =~ ^[0-9]+$ ]] && (( PORT_VALUE < 1024 )) && [[ $(id -u) -ne 0 ]]; then
  info "Granting cap_net_bind_service to bun for port ${PORT_VALUE}"
  $SUDO /sbin/setcap 'cap_net_bind_service=+ep' "$BUN_BIN" || warn "setcap failed; use non-privileged port"
fi

info "Starting service"
$SUDO systemctl restart "$SERVICE_NAME"
sleep 1

if systemctl is-active --quiet "$SERVICE_NAME"; then
  log "Service active"
else
  warn "Service not active yet"
fi

info "Status:"
$SUDO systemctl status "$SERVICE_NAME" -l || true

info "Recent logs:"
journalctl -u "$SERVICE_NAME" --since -2min || true

log "Setup complete."
