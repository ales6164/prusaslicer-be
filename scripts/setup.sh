#!/usr/bin/env bash
# scripts/setup.sh — ultra-verbose Fedora setup for prusaslicer-be
# Run from repo root: bash ./scripts/setup.sh

###############################################################################
# Strict + rich tracing
###############################################################################
set -Eeuo pipefail
export LC_ALL=C
export LANG=C
export TZ=UTC

# Timestamped xtrace
export PS4='+ [${EPOCHREALTIME}] ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-main}() -> '
set -x

# Error trap with context
trap 'rc=$?; echo "[FATAL] exit $rc at ${BASH_SOURCE}:${LINENO} in ${FUNCNAME[0]:-main}"; exit $rc' ERR

###############################################################################
# Helpers
###############################################################################
log()  { printf '[OK] %s\n' "$*" ; }
info() { printf '[INFO] %s\n' "$*" ; }
warn() { printf '[WARN] %s\n' "$*" ; }
err()  { printf '[ERR] %s\n' "$*" >&2 ; }

SUDO=sudo
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then SUDO=""; fi

require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "missing cmd: $1"; exit 127; }; }

dnf_install_or_update() {
  local pkg="$1"
  if rpm -q "$pkg" >/dev/null 2>&1; then
    info "dnf upgrade --refresh -y $pkg"
    $SUDO dnf upgrade --refresh -y "$pkg" || warn "upgrade $pkg failed or latest"
  else
    info "dnf install -y $pkg"
    $SUDO dnf install -y "$pkg"
  fi
  rpm -q "$pkg" || { err "$pkg not installed after dnf"; exit 1; }
}

check_file_exec() {
  local p="$1"
  [[ -f "$p" ]] || { err "not a file: $p"; return 1; }
  [[ -x "$p" ]] || { err "not executable: $p"; return 1; }
  file "$p" || true
  ldd "$p" || true
}

###############################################################################
# Preamble: print context
###############################################################################
info "whoami=$(id -un) uid=$(id -u) gid=$(id -g) home=$HOME shell=$SHELL"
info "pwd=$(pwd)"
info "ls -la repo root:"
ls -la
info "uname -a:"
uname -a
info "Fedora release:"
cat /etc/os-release || true
info "PATH=$PATH"

# Validate we are in repo root
[[ -f package.json && -d src ]] || { err "Run from repo root (missing package.json or src)"; exit 1; }

###############################################################################
# Repos and tooling
###############################################################################
require_cmd dnf
require_cmd curl
require_cmd systemctl
require_cmd bash
require_cmd tee

# Optional: ensure journald is persistent so we get logs
if [[ ! -d /var/log/journal ]]; then
  info "Enabling persistent journald"
  $SUDO mkdir -p /var/log/journal
  $SUDO systemctl restart systemd-journald
fi
$SUDO systemctl is-active systemd-journald || $SUDO systemctl start systemd-journald || true

# Packages
dnf_install_or_update prusa-slicer
dnf_install_or_update unzip
dnf_install_or_update git

###############################################################################
# Git sanity: make sure repo is cleanly pulled (optional but logged)
###############################################################################
if [[ -d .git ]]; then
  info "git remote -v:"; git remote -v || true
  info "git status -sb:"; git status -sb || true
  info "git fetch --all --prune"
  git fetch --all --prune || warn "git fetch failed"
  info "git rev-parse HEAD && git show -s --format=%ci HEAD"
  git rev-parse HEAD && git show -s --format=%ci HEAD || true
fi

###############################################################################
# Bun install or update with zero RC-file sourcing
###############################################################################
BUN_BIN="$(command -v bun || true)"
if [[ -z "${BUN_BIN}" ]]; then
  info "Installing Bun via official script"
  curl -fsSL https://bun.sh/install | bash
  export PATH="${HOME}/.bun/bin:${PATH}"
  BUN_BIN="${HOME}/.bun/bin/bun"
  check_file_exec "$BUN_BIN"
  "$BUN_BIN" --version
  log "Bun installed at $BUN_BIN"
else
  info "Found Bun at $BUN_BIN"
  "$BUN_BIN" --version || true
  info "bun upgrade"
  "$BUN_BIN" upgrade || warn "bun upgrade failed or already latest"
  export PATH="$(dirname "$BUN_BIN"):${PATH}"
  "$BUN_BIN" --version
fi

# Prove Bun can execute in this shell
info "Bun self-check"
"$BUN_BIN" -e 'console.log("bun-ok")'

###############################################################################
# Dependencies
###############################################################################
info "bun install"
"$BUN_BIN" install

###############################################################################
# Preflight: run the app like systemd will (same cwd, same command)
###############################################################################
# Determine Exec command exactly as unit will use
EXEC_CMD=("$BUN_BIN" run src/server.ts)

info "Dry-run server preflight (5s timeout). This will fail fast if ExecStart is wrong."
set +e
( setsid bash -c "cd '$(pwd)'; exec ${EXEC_CMD[*]}" ) &
app_pid=$!
sleep 5
if ps -p "$app_pid" >/dev/null 2>&1; then
  info "Preflight server is running (pid $app_pid). Killing to continue."
  kill "$app_pid" || true
  sleep 1
  kill -9 "$app_pid" 2>/dev/null || true
  preflight_ok=1
else
  warn "Preflight server not detected running after 5s. This may be fine if it exits quickly or crashes. Proceeding."
  preflight_ok=0
fi
set -e

###############################################################################
# Systemd unit generation
###############################################################################
SERVICE_NAME="prusaslicer-be.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
WORKDIR="$(pwd)"

info "Writing systemd unit -> $SERVICE_PATH"
UNIT_CONTENT="[Unit]
Description=prusaslicer-be Bun backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
WorkingDirectory=${WORKDIR}
# Use explicit entry, avoid package.json scripts indirection for clarity
ExecStart=${BUN_BIN} run src/server.ts
Restart=on-failure
RestartSec=3
Environment=HOME=${HOME}
Environment=NODE_ENV=production
Environment=PATH=${HOME}/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=prusaslicer-be

# Hardening (keep JIT allowed)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
LockPersonality=true
MemoryDenyWriteExecute=false

[Install]
WantedBy=multi-user.target
"

printf "%s" "${UNIT_CONTENT}" | $SUDO tee "${SERVICE_PATH}" >/dev/null

info "Unit content written:"
$SUDO sed -n '1,200p' "${SERVICE_PATH}"

# Verify unit syntax
info "systemd-analyze verify ${SERVICE_PATH}"
$SUDO systemd-analyze verify "${SERVICE_PATH}" || warn "systemd-analyze reported issues"

info "daemon-reload + enable"
$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}"

###############################################################################
# If binding to privileged port (e.g., 80) and running as non-root, grant cap
###############################################################################
# Autodetect PORT from env file if present
PORT_VALUE="${PORT:-}"
if [[ -f .env ]]; then
  info "Reading .env for PORT if set"
  # shellcheck disable=SC2046
  export $(grep -E '^(PORT)=' .env | xargs -d '\n' -r)
  PORT_VALUE="${PORT:-$PORT_VALUE}"
fi
info "Detected PORT=${PORT_VALUE:-unset}"
if [[ "${PORT_VALUE:-}" =~ ^[0-9]+$ ]] && (( PORT_VALUE < 1024 )); then
  if [[ $(id -u) -ne 0 ]]; then
    info "Granting cap_net_bind_service to Bun for low port ${PORT_VALUE}"
    $SUDO /sbin/setcap 'cap_net_bind_service=+ep' "$BUN_BIN" || warn "setcap failed; low ports may fail"
    /sbin/getcap "$BUN_BIN" || true
  else
    info "Running as root; low port ${PORT_VALUE} is allowed."
  fi
fi

###############################################################################
# Start service and inspect
###############################################################################
info "Starting service"
$SUDO systemctl restart "${SERVICE_NAME}" || true

sleep 1
info "systemctl status:"
$SUDO systemctl status "${SERVICE_NAME}" -l || true

# Force generate some logs before checking journal
sleep 2
info "journalctl -u ${SERVICE_NAME} --since -2min:"
journalctl -u "${SERVICE_NAME}" --since -2min || true

# Final health check loop with backoff and curl if port is known
tries=10
while (( tries-- > 0 )); do
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    log "Service ${SERVICE_NAME} active"
    break
  fi
  warn "Service not active yet, retrying..."
  sleep 1
done

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
  err "Service failed to become active."
  echo "---- Diagnostics ----"
  $SUDO systemctl status "${SERVICE_NAME}" -l || true
  journalctl -u "${SERVICE_NAME}" -b || true
  echo "Exec binary check:"
  check_file_exec "$BUN_BIN" || true
  exit 1
fi

log "Setup complete."
