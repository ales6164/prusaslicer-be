#!/usr/bin/env bash
# Fedora setup for prusaslicer-be (idempotent, verbose, with git auto-reexec)

set -Eeuo pipefail

log(){ printf '[OK] %s\n' "$*"; }
info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
err(){ printf '[ERR] %s\n' "$*" >&2; }

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

# Ensure persistent journald for logs
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

# Base packages
dnf_install_or_update prusa-slicer
dnf_install_or_update unzip
dnf_install_or_update git
dnf_install_or_update policycoreutils-python-utils || true  # for restorecon if available

###############################################################################
# Bun install/update -> place in /usr/local/bin for systemd (with wrapper fallback)
###############################################################################
install_or_update_bun() {
  set -euo pipefail
  local user_bun="$HOME/.bun/bin/bun"
  local sys_bun="/usr/local/bin/bun"

  # Ensure bash
  [[ -n "${BASH_VERSION:-}" ]] || { err "Run with bash"; exit 1; }

  # Install or upgrade user bun
  if [[ ! -x "$user_bun" ]]; then
    info "Installing Bun (user) -> $user_bun"
    curl -fsSL https://bun.sh/install | bash
  else
    info "Upgrading Bun (user)"
    "$user_bun" upgrade || true
  fi

  # Verify user bun
  [[ -x "$user_bun" ]] || { err "Bun not found at $user_bun"; exit 1; }
  info "user bun version: $("$user_bun" --version 2>&1)"

  # Install to /usr/local/bin for systemd
  if [[ ! -x "$sys_bun" ]] || ! cmp -s "$user_bun" "$sys_bun"; then
    info "Installing system bun -> $sys_bun"
    $SUDO install -m 0755 -o root -g root "$user_bun" "$sys_bun"
    command -v restorecon >/dev/null 2>&1 && $SUDO restorecon -v "$sys_bun" || true
  fi

  # Rehash then verify; if binary fails to exec, install a wrapper script
  hash -r || true
  if ! "$sys_bun" --version >/dev/null 2>&1; then
    warn "Direct exec failed at $sys_bun. Falling back to wrapper."
    info "file: $(file -b "$sys_bun" 2>&1)"
    command -v ldd >/dev/null 2>&1 && ldd "$sys_bun" || true
    command -v findmnt >/dev/null 2>&1 && findmnt -no TARGET,OPTIONS /usr/local || true

    $SUDO bash -c "cat > '$sys_bun' <<'WRAP'
#!/usr/bin/env bash
exec \"$HOME/.bun/bin/bun\" \"\$@\"
WRAP
chmod 0755 '$sys_bun'"
  fi

  # Final verify
  "$sys_bun" --version >/dev/null 2>&1 || { err "System bun not runnable"; exit 1; }
  log "Bun ready at $sys_bun"
  echo "$sys_bun"
}

BUN_BIN="$(install_or_update_bun)"
info "System bun: $("$BUN_BIN" --version)"

# Dependencies
info "bun install"
"$BUN_BIN" install
log "Dependencies installed"

# Preflight (5s)
info "Preflight: $BUN_BIN run src/server.ts"
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
ExecStart=/usr/local/bin/bun run src/server.ts
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
  $SUDO /sbin/setcap 'cap_net_bind_service=+ep' /usr/local/bin/bun || warn "setcap failed; use non-privileged port"
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
