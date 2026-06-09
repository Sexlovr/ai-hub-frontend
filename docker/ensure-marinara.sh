#!/usr/bin/env bash
# Fetch Marinara lite tree on first open if not baked into the image.
set -uo pipefail

DATA_ROOT="${DATA_ROOT:-/data}"
DEST="/apps/marinara"
MARKER="${DATA_ROOT}/marinara/.installed"

if [[ -f "${DEST}/packages/server/dist/index.js" ]]; then
  exit 0
fi

if [[ -f "${MARKER}" ]]; then
  echo "[marinara] WARN: marker set but dist missing" >&2
fi

echo "[marinara] first-time fetch (shallow clone)…" >&2
mkdir -p "${DATA_ROOT}/marinara" "${DEST}"

TMP="${DATA_ROOT}/.marinara-clone"
rm -rf "${TMP}"
git clone --depth 1 --branch main https://github.com/Pasta-Devs/Marinara-Engine.git "${TMP}"

# Lite runtime needs server dist + workspace deps — use prebuilt docker layout when possible.
if [[ -f "${TMP}/packages/server/dist/index.js" ]]; then
  rsync -a "${TMP}/" "${DEST}/"
else
  echo "[marinara] building server package (one-time, ~2–5 min)…" >&2
  cd "${TMP}"
  if command -v corepack >/dev/null 2>&1; then
    corepack enable 2>/dev/null || true
  fi
  npm install -g pnpm 2>/dev/null || true
  pnpm install --frozen-lockfile 2>&1 || npm ci 2>&1 || true
  pnpm --filter @marinara/server build 2>&1 || npm run build -w packages/server 2>&1 || true
  rsync -a "${TMP}/" "${DEST}/"
fi

rm -rf "${TMP}"
touch "${MARKER}" 2>/dev/null || true

if [[ -d /apps/marinara ]]; then
  /opt/hub/docker/patch-marinara-sw.sh 2>&1 || true
  /opt/hub/docker/patch-app-subpaths.sh 2>&1 || true
fi

echo "[marinara] ready at ${DEST}" >&2