#!/usr/bin/env bash
set -euo pipefail

# Usage: bash ./scripts/update.sh
# Pull latest, install deps, then start/restart service.

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$REPO_DIR"

echo "[update] updating git"
git fetch --all
git reset --hard origin/main

echo "[update] ensuring Bun on PATH"
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export PATH="$BUN_INSTALL/bin:$PATH"

echo "[update] installing deps"
bun install

echo "[update] done"
