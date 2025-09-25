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
dnf_install_or_update "git"

# ---------- Bun install or update ----------
# Try to find bun in PATH, else install under current user's home.
BUN_BIN="$(command -v bun || true)"
if [[ -z "${BUN_BIN}" ]]; then
  info "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash
  # Best-effort source common profiles to expose ~/.bun/bin
  [[ -f "${HOME}/.bashrc"   ]] && . "${HOME}/.bashrc"   || true
  [[ -f "${HOME}/.profile"  ]] && . "${HOME}/.profile"  || true
  [[ -f "${HOME}/.bash_profile" ]] && . "${HOME}/.bash_profile" || true
  BUN_BIN="$(command -v bun || true)"
  if [[ -z "${BUN_BIN}" && -x "${HOME}/.bun/bin/bun" ]]; then
    BUN_BIN="${HOME}/.bun/bin/bun"
  fi
  [[ -x "${BUN_BIN:-}" ]] || { err "Bun installation did not yield an executable"; exit 1; }
  log "Bun installed at ${BUN_BIN}"
else
  info "Bun present at ${BUN_BIN}. Updating to latest stable..."
  "${BUN_BIN}" upgrade || warn "bun upgrade failed or already latest"
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
ExecStart=${BUN_BIN} run src/server.ts
Restart=always
RestartSec=3
Environment=NODE_ENV=production
Environment=PATH=${HOME}/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
LockPersonality=true
MemoryDenyWriteExecute=true

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
