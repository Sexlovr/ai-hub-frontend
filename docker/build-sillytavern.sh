#!/usr/bin/env bash
# Build SillyTavern from upstream git — hub controls version + overlays.
set -euo pipefail

ST_REF="${ST_REF:-1.18.0}"
ST_ROOT="${ST_ROOT:-/apps/sillytavern}"
HUB_ROOT="${HUB_ROOT:-/opt/hub}"

echo "[hub] building SillyTavern from git tag ${ST_REF}" >&2

rm -rf "${ST_ROOT}"
git clone --depth 1 --branch "${ST_REF}" \
  https://github.com/SillyTavern/SillyTavern.git "${ST_ROOT}"

cd "${ST_ROOT}"
echo "[hub] npm ci (production)..." >&2
npm ci --omit=dev

echo "[hub] webpack build (docker/build-lib.js)..." >&2
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=2048}"
node docker/build-lib.js

export ST_ROOT
export OVERLAY="${HUB_ROOT}/overlays/sillytavern"
bash "${HUB_ROOT}/overlays/sillytavern/patches/apply-patches.sh"

# Shrink image layer — less COPY time/RAM on HF build workers.
rm -rf .git .github tests .vscode 2>/dev/null || true
find . -name "*.map" -type f -delete 2>/dev/null || true
npm prune --omit=dev 2>/dev/null || true

# Image-level marker: webpack already ran — skip npm init + recompile on first boot.
touch "${ST_ROOT}/.hub-built"
echo "${ST_REF}" > "${ST_ROOT}/.hub-st-ref"

echo "[hub] SillyTavern ${ST_REF} ready at ${ST_ROOT}" >&2