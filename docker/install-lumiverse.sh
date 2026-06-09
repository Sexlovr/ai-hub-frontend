#!/usr/bin/env bash
# Build Lumiverse on first use into /data (keeps Docker build small for HF).
set -euo pipefail

DATA_ROOT="${DATA_ROOT:-/data}"
MARKER="${DATA_ROOT}/lumiverse/.built"
SRC="/apps/lumiverse-src"
DEST="${DATA_ROOT}/lumiverse-app"

if [[ -f "${MARKER}" ]]; then
  echo "[lumiverse] already built" >&2
  exit 0
fi

echo "[lumiverse] first-time build — this takes several minutes…" >&2
mkdir -p "${DATA_ROOT}/lumiverse" "${DEST}"

if [[ ! -d "${SRC}/.git" ]]; then
  git clone --depth 1 https://github.com/prolix-oc/Lumiverse.git "${SRC}"
fi

rsync -a "${SRC}/" "${DEST}/"
cd "${DEST}"
sed -i 's/c.req.header("host")/c.req.header("x-forwarded-host") || c.req.header("host")/g' src/app.ts || true
sed -i 's/`http:\/\/${host}`/`${(c.req.header("x-forwarded-proto") || "http")}:\/\/${host}`/g' src/app.ts || true

cd frontend
bun install && bun run build
cd ..
bun install --production

touch "${MARKER}"
echo "[lumiverse] build complete" >&2