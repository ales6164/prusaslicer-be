#!/usr/bin/env bash
# scripts/setup.sh — Fedora setup for prusaslicer-be
# Run from repo root: bash ./scripts/setup.sh

###############################################################################
# Strict + tracing
###############################################################################
set -Eeuo pipefail
export LC_ALL=C LANG=C TZ=UTC
export PS4='+ [${EPOCHREALTIME}] ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-main}() -> '
set -x
trap 'rc=$?; echo "[FATAL] exit $rc at ${BASH_SOURCE}:${LINENO} in ${FUNCNAME[0]:-main}"; exit $rc' ERR

###############################################################################
# Helpers
###############################################################################
log(){ printf '[OK] %s\n' "$*"; }
info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
err(){ printf '[ERR] %s\n' "$*" >&2; }

[[ -f package.json && -d src ]] || { err "Run from repo root"; exit 1; }

SUDO=sudo; [[ ${EUID:-$(id -u)} -eq 0 ]] && SUDO=""

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "missing cmd: $1"; exit 127; }; }

dnf_install_or_update() {
  local pkg="$1"
  if rpm -q "$pkg" >/dev/null 2>&1; then
    info "dnf upgrade --refresh -y $pkg"
    $SUDO dnf upgrade --refresh -y "$pkg" || warn "upgrade $pkg failed or latest"
  else
    info "dnf install -y $pkg"
    $SUDO dnf install -y "$pkg"
  fi
  rpm -q "$pkg" >/dev/null 2>&1 || { err "$pkg not installed after dnf"; exit 1; }
}

check_file_exec() {
  local p="$1"
  [[ -f "$p" ]] || { err "not a file: $p"; return 1; }
  [[ -x "$p" ]] || { err "not executable: $p"; return 1; }
  file "$p" || true
  ldd "$p" || true
}

###############################################################################
# Preamble
###############################################################################
require_cmd dnf; require_cmd curl; require_cmd systemctl; require_cmd bash; require_cmd tee
info "whoami=$(id -un) uid=$(id -u) gid=$(id -g) home=$HOME shell=$SHELL"
info "pwd=$(pwd)"; ls -la
uname -a || true
cat /etc/os-release || true
info "PATH=$PATH"

# journald persistent logs (optional)
if [[ ! -d /var/log/journal ]]; then
  info "Enabling persistent journald"
  $SUDO mkdir -p /var/log/journal
  $SUDO systemctl restart systemd-journald || true
fi
$SUDO systemctl is-active systemd-journald || $SUDO systemctl start systemd-journald || true

# base packages
dnf_install_or_update prusa-slicer
dnf_install_or_update unzip
dnf_install_or_update git
# SELinux tools if missing (restorecon lives in policycoreutils)
dnf_install_or_update policycoreutils || true

###############################################################################
# Git fast-forward update + one-time re-exec
###############################################################################
if [[ -d .git ]]; then
  info "Checking for repo updates"
  set +e; upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); set -e
  if [[ -n "${upstream:-}" ]]; then
    before=$(git rev-parse HEAD)
    git fetch --all --prune || warn "git fetch failed"
    if git merge --ff-only "$upstream"; then
      after=$(git rev-parse HEAD)
      if [[ "$before" != "$after" ]]; then
        info "Repo updated: $before -> $after"
        if [[ "${SETUP_REEXEC:-0}" -lt 1 ]]; then
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

###############################################################################
# Bun: ensure /usr/local/bin/bun with proper SELinux context
###############################################################################
TARGET_BUN="/usr/local/bin/bun"

install_bun_to_usr_local() {
  local src=""
  # 1) If bun already in PATH, prefer that as source
  if command -v bun >/dev/null 2>&1; then
    src="$(command -v bun)"
  elif [[ -x "${HOME}/.bun/bin/bun" ]]; then
    src="${HOME}/.bun/bin/bun"
  elif [[ -x "/root/.bun/bin/bun" ]]; then
    src="/root/.bun/bin/bun"
  else
    info "Installing Bun via official script"
    # install to current user's ~/.bun
    curl -fsSL https://bun.sh/install | bash
    src="${HOME}/.bun/bin/bun"
  fi

  [[ -x "$src" ]] || { err "Bun binary not found after install"; exit 1; }

  info "Copying Bun -> ${TARGET_BUN}"
  $SUDO cp -f "$src" "${TARGET_BUN}"
  $SUDO chown root:root "${TARGET_BUN}"
  $SUDO chmod 0755 "${TARGET_BUN}"
  if command -v restorecon >/dev/null 2>&1; then
    $SUDO restorecon -v "${TARGET_BUN}" || true
  fi
  check_file_exec "${TARGET_BUN}" || true
  "${TARGET_BUN}" --version
  log "Bun ready at ${TARGET_BUN}"
}

if [[ ! -x "${TARGET_BUN}" ]]; then
  install_bun_to_usr_local
else
  info "Found ${TARGET_BUN}"
  "${TARGET_BUN}" --version || true
  # Try upgrade without network failure aborting script
  "${TARGET_BUN}" upgrade || warn "bun upgrade failed or already latest"
fi

# Self-check
info "Bun self-check"
"${TARGET_BUN}" -e 'console.log("bun-ok")'

###############################################################################
# Dependencies via Bun
###############################################################################
info "bun install"
"${TARGET_BUN}" install

###############################################################################
# Preflight: run the app briefly
###############################################################################
EXEC_CMD=("${TARGET_BUN}" run src/server.ts)
info "Dry-run server preflight (5s timeout)"
set +e
( setsid bash -c "cd '$(pwd)'; exec ${EXEC_CMD[*]}" ) &
app_pid=$!
sleep 5
if ps -p "$app_pid" >/dev/null 2>&1; then
  info "Preflight server running (pid $app_pid). Killing."
  kill "$app_pid" || true; sleep 1; kill -9 "$app_pid" 2>/dev/null || true
else
  warn "Preflight not detected as running after 5s. Proceeding."
fi
set -e

###############################################################################
# systemd unit
###############################################################################
SERVICE_NAME="prusaslicer-be.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
WORKDIR="$(pwd)"

UNIT_CONTENT="[Unit]
Description=prusaslicer-be Bun backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
WorkingDirectory=${WORKDIR}
ExecStart=${TARGET_BUN} run src/server.ts
Restart=on-failure
RestartSec=3
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
"

info "Writing systemd unit -> ${SERVICE_PATH}"
printf "%s" "${UNIT_CONTENT}" | $SUDO tee "${SERVICE_PATH}" >/dev/null
$SUDO sed -n '1,200p' "${SERVICE_PATH}"

info "systemd-analyze verify ${SERVICE_PATH}"
$SUDO systemd-analyze verify "${SERVICE_PATH}" || warn "systemd-analyze reported issues"

info "daemon-reload + enable"
$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}"

###############################################################################
# Low port capability if needed
###############################################################################
PORT_VALUE="${PORT:-}"
if [[ -f .env ]]; then
  info "Reading .env for PORT"
  # shellcheck disable=SC2046
  export $(grep -E '^(PORT)=' .env | xargs -d '\n' -r)
  PORT_VALUE="${PORT:-$PORT_VALUE}"
fi
info "Detected PORT=${PORT_VALUE:-unset}"
if [[ "${PORT_VALUE:-}" =~ ^[0-9]+$ ]] && (( PORT_VALUE < 1024 )); then
  if [[ $(id -u) -ne 0 ]]; then
    info "Granting cap_net_bind_service to ${TARGET_BUN}"
    $SUDO /sbin/setcap 'cap_net_bind_service=+ep' "${TARGET_BUN}" || warn "setcap failed; low ports may fail"
    /sbin/getcap "${TARGET_BUN}" || true
  else
    info "Running as root; low port allowed"
  fi
fi

###############################################################################
# Start + diagnostics
###############################################################################
info "Starting service"
$SUDO systemctl restart "${SERVICE_NAME}" || true
sleep 1
info "systemctl status:"; $SUDO systemctl status "${SERVICE_NAME}" -l || true
sleep 2
info "journalctl -u ${SERVICE_NAME} --since -2min:"; journalctl -u "${SERVICE_NAME}" --since -2min || true

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
  echo "Exec binary check:"; check_file_exec "${TARGET_BUN}" || true
  exit 1
fi

log "Setup complete."
