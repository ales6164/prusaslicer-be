#!/usr/bin/env bash
set -euo pipefail

# Run as:  bash setup.sh
# Optional:  chmod +x setup.sh && ./setup.sh

echo "[1/7] Updating apt"
sudo apt update

echo "[2/7] Installing basics"
sudo apt install -y curl ca-certificates flatpak

echo "[3/7] Installing Bun"
# non-interactive
curl -fsSL https://bun.sh/install | bash
# make bun available in current shell + future logins
if ! command -v bun >/dev/null 2>&1; then
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi
grep -q 'BUN_INSTALL' "$HOME/.bashrc" || {
  echo 'export BUN_INSTALL="$HOME/.bun"' >> "$HOME/.bashrc"
  echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$HOME/.bashrc"
}

echo "[4/7] Installing Flathub + PrusaSlicer"
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.prusa3d.PrusaSlicer

# Ensure PrusaSlicer can access host filesystem when run headless
echo "[5/7] Granting filesystem access to PrusaSlicer"
flatpak override --user --filesystem=host com.prusa3d.PrusaSlicer

echo "[6/7] Verifying installs"
bun --version
flatpak run --command=prusa-slicer com.prusa3d.PrusaSlicer --help >/dev/null

echo "[7/7] Installing server deps"
# project root assumed as current dir
bun install

echo "OK. Bun and PrusaSlicer CLI are usable."
echo "Start server: bun run src/index.ts"
.