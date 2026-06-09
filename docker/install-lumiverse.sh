#!/usr/bin/env bash
# Build Lumiverse on first use into /data/lumiverse-app (not in Dockerfile).
set -euo pipefail

DATA_ROOT="${DATA_ROOT:-/data}"
MARKER="${DATA_ROOT}/lumiverse/.built"
SRC="${DATA_ROOT}/lumiverse-src"
DEST="${LUMIVERSE_ROOT:-/data/lumiverse-app}"

if [[ -f "${MARKER}" && -f "${DEST}/src/index.ts" ]]; then
  echo "[lumiverse] already built at ${DEST}" >&2
  exit 0
fi

echo "[lumiverse] first-time build into ${DEST}…" >&2
mkdir -p "${DATA_ROOT}/lumiverse" "${DEST}"

if [[ ! -d "${SRC}/.git" ]]; then
  git clone --depth 1 https://github.com/prolix-oc/Lumiverse.git "${SRC}"
fi

rsync -a "${SRC}/" "${DEST}/"
cd "${DEST}"
sed -i 's/c.req.header("host")/c.req.header("x-forwarded-host") || c.req.header("host")/g' src/app.ts 2>/dev/null || true
sed -i 's/`http:\/\/${host}`/`${(c.req.header("x-forwarded-proto") || "http")}:\/\/${host}`/g' src/app.ts 2>/dev/null || true

export PATH="${HOME}/.bun/bin:/usr/local/bin:${PATH}"
cd frontend
bun install && bun run build
cd ..
bun install --production

if [[ -d /data/lumiverse-app/frontend/dist ]]; then
  /opt/hub/docker/patch-lumiverse-auth.sh 2>&1 || true
  /opt/hub/docker/patch-lumiverse-sw.sh 2>&1 || true
  /opt/hub/docker/patch-app-subpaths.sh 2>&1 || true
fi

touch "${MARKER}"
echo "[lumiverse] build complete at ${DEST}" >&2