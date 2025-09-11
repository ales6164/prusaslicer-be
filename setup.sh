#!/usr/bin/env bash
set -euo pipefail

# Run in repo root.
NAME="prusaslicer-be"
ACME_ROOT="/var/www/acme"
# Point ACME_DIR to the challenge folder so Bun reads tokens where certbot writes them.
ACME_DIR="$ACME_ROOT/.well-known/acme-challenge"

echo "[1/7] apt update"
sudo apt update

echo "[2/7] Install basics"
sudo apt install -y curl ca-certificates flatpak

echo "[3/7] Prepare ACME webroot"
sudo mkdir -p "$ACME_DIR"
sudo chown -R "$USER":"$USER" "$ACME_ROOT"

echo "[4/7] Install Bun"
curl -fsSL https://bun.sh/install | bash
if ! command -v bun >/dev/null 2>&1; then
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi
grep -q 'BUN_INSTALL' "$HOME/.bashrc" || {
  echo 'export BUN_INSTALL="$HOME/.bun"' >> "$HOME/.bashrc"
  echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$HOME/.bashrc"
}

echo "[5/7] Install Flathub + PrusaSlicer"
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.prusa3d.PrusaSlicer
flatpak override --user --filesystem=host com.prusa3d.PrusaSlicer

echo "[6/7] Verify tools"
bun --version
flatpak run --command=prusa-slicer com.prusa3d.PrusaSlicer --help >/dev/null

echo "[7/7] Project deps"
bun install

# Optional local .env defaults (HTTP only by default; HTTPS enabled after TLS setup)
cat > .env <<EOF
# Server ports
HTTP_PORT=80
PORT=8080
# TLS off initially. scripts/setup_tls.sh will enable HTTPS in systemd env.
HTTPS=
# ACME webroot used by index.ts ACME handler
ACME_DIR=$ACME_DIR
# DOMAIN will be set during TLS setup
DOMAIN=
EOF

echo "OK. Base setup done. Start HTTP server: bun run src/index.ts"
echo "For TLS, run: scripts/setup_tls.sh"
