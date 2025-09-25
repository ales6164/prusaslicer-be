#!/usr/bin/env bash
# scripts/setup.sh
# Fedora setup for PrusaSlicer + Bun for the already-cloned prusaslicer-be repo.
# Assumptions:
# - You already installed git and cloned this repo.
# - You run this from inside the repo directory (prusaslicer-be).
# Actions:
# - Install or update prusa-slicer via dnf.
# - Install or update Bun.
# - Run `bun install`.
# - Create/refresh a systemd service that runs `bun run src/server.ts`.

set -euo pipefail

# ---------- helpers ----------
log()  { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
info() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; }

# Must be executed from repo root
if [[ ! -f "package.json" || ! -d "src" ]]; then
  err "Run this script from the prusaslicer-be repo root (found no package.json/src)"
  exit 1
fi

# SUDO helper. If already root, no sudo.
SUDO=sudo
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then SUDO=""; fi

# Required base tools
command -v dnf >/dev/null || { err "dnf not found"; exit 1; }
command -v curl >/dev/null || { err "curl not found"; exit 1; }
command -v systemctl >/dev/null || { err "systemctl not found"; exit 1; }


# ---------- dnf install or update ----------
dnf_install_or_update() {
  local pkg="$1"
  if rpm -q "$pkg" >/dev/null 2>&1; then
    info "Updating $pkg to latest available..."
    $SUDO dnf upgrade --refresh -y "$pkg" || warn "dnf upgrade $pkg failed or already latest"
  else
    info "Installing $pkg..."
    $SUDO dnf install -y "$pkg"
  fi
  log "$pkg ready"
}

# prusa-slicer GUI package
dnf_install_or_update "prusa-slicer"
# git for repo updates
dnf_install_or_update "git"
# unzip for Bun installation
dnf_install_or_update "unzip"

# Pull latest changes from repo
if command -v git >/dev/null 2>&1; then
  if [[ -d ".git" ]]; then
    info "Pulling latest changes from git..."
    git fetch --all --prune
    if ! git merge --ff-only @{u}; then
      warn "git pull failed (divergence?) – manual resolution needed"
    else
      log "Git repo up to date"
    fi
  else
    warn "Not a git repo (no .git); skipping git pull"
  fi
else
  warn "git not found; skipping git pull"
fi

# ---------- Bun install or update ----------
BUN_BIN="$(command -v bun || true)"
if [[ -z "${BUN_BIN}" ]]; then
  info "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash

  # Do NOT source ~/.bashrc; avoid /etc/bashrc with set -u
  export PATH="${HOME}/.bun/bin:${PATH}"

  if [[ -x "${HOME}/.bun/bin/bun" ]]; then
    BUN_BIN="${HOME}/.bun/bin/bun"
  else
    err "Bun installation did not yield an executable at ~/.bun/bin/bun"
    exit 1
  fi
  log "Bun installed at ${BUN_BIN}"
else
  info "Bun present at ${BUN_BIN}. Updating to latest stable..."
  "${BUN_BIN}" upgrade || warn "bun upgrade failed or already latest"
  export PATH="$(dirname "${BUN_BIN}"):${PATH}"
  log "Bun ready: version $(${BUN_BIN} --version)"
fi

# ---------- bun install in repo ----------
info "Installing dependencies with Bun..."
"${BUN_BIN}" install
log "Dependencies installed"

# ---------- systemd service setup ----------
# Service will run as the current user. If you run this as root, service runs as root.
SERVICE_NAME="prusaslicer-be.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
WORKDIR="$(pwd)"

# Stop existing unit if present (before overwrite)
if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
  info "Stopping existing service if running..."
  $SUDO systemctl stop "${SERVICE_NAME}" || true
fi

info "Writing systemd unit to ${SERVICE_PATH}..."
UNIT_CONTENT="[Unit]
Description=prusaslicer-be Bun backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Group=$(id -gn)
WorkingDirectory=${WORKDIR}
ExecStart=${BUN_BIN} start
Restart=on-failure
RestartSec=3
Environment=NODE_ENV=production
Environment=PATH=${HOME}/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
# Optional: make HOME explicit for Bun and any scripts
Environment=HOME=${HOME}

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=prusaslicer-be

# Hardening (safe subset)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
LockPersonality=true
# Bun needs W^X memory; do NOT enable MDWE
MemoryDenyWriteExecute=false

[Install]
WantedBy=multi-user.target
"

printf "%s" "${UNIT_CONTENT}" | $SUDO tee "${SERVICE_PATH}" >/dev/null

info "Reloading systemd and enabling service..."
$SUDO systemctl daemon-reload
$SUDO systemctl enable "${SERVICE_NAME}"

info "Starting service..."
$SUDO systemctl restart "${SERVICE_NAME}"

sleep 1
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  log "Service '${SERVICE_NAME}' is running."
  info "Follow logs: journalctl -u ${SERVICE_NAME} -f"
else
  err "Service failed to start. Inspect logs:"
  echo "  journalctl -u ${SERVICE_NAME} -e -n 200"
  exit 1
fi
