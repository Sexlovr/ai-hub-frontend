#!/usr/bin/env bash
set -uo pipefail

DATA_ROOT="${DATA_ROOT:-/data}"
ST_PORT="${ST_PORT:-8000}"
ST_DATA="${DATA_ROOT}/sillytavern"
ST_CONFIG="${ST_DATA}/config/config.yaml"
INIT_MARKER="${ST_DATA}/.npm-init-done"

ST_INSTALL="${ST_INSTALL_ROOT:-/data/st-app}"
HUB_BUILT="${ST_INSTALL}/.hub-built"
if [[ ! -f "${ST_INSTALL}/server.js" && -d /apps/sillytavern ]]; then
  ST_INSTALL="/apps/sillytavern"
  HUB_BUILT="${ST_INSTALL}/.hub-built"
fi
echo "[sillytavern] starting on port ${ST_PORT} (${ST_INSTALL}, ST_REF=${ST_REF:-1.18.0})" >&2
cd "${ST_INSTALL}"

if [[ -x /opt/hub/overlays/sillytavern/patches/apply-patches.sh ]]; then
  ST_ROOT=/apps/sillytavern OVERLAY=/opt/hub/overlays/sillytavern \
    bash /opt/hub/overlays/sillytavern/patches/apply-patches.sh 2>&1 || true
fi

export NODE_ENV=production
export SILLYTAVERN_LISTEN=true
export SILLYTAVERN_WHITELISTMODE=false
export SILLYTAVERN_ENABLEFORWARDEDWHITELIST=false
export SILLYTAVERN_HOSTWHITELIST_ENABLED=false
export SILLYTAVERN_DISABLECSRF=true
export SILLYTAVERN_LISTENADDRESS_IPV4=0.0.0.0
export SILLYTAVERN_PORT="${ST_PORT}"

mkdir -p "${ST_DATA}/config" "${ST_DATA}/data/default-user"
cp /opt/hub/config/sillytavern-config.yaml "${ST_CONFIG}"

rm -rf config data 2>/dev/null || true
ln -sfn "${ST_DATA}/config" config
ln -sfn "${ST_DATA}/data" data
rm -f config.yaml 2>/dev/null || true
ln -sfn "${ST_CONFIG}" config.yaml

if [[ -f "${HUB_BUILT}" && ! -f "${INIT_MARKER}" ]]; then
  echo "[sillytavern] hub-built image — skipping npm init (webpack done at image build)" >&2
  touch "${INIT_MARKER}"
elif [[ ! -f "${INIT_MARKER}" ]]; then
  echo "[sillytavern] first-time config init..." >&2
  npm run init 2>&1 || true
  touch "${INIT_MARKER}"
else
  echo "[sillytavern] skipping npm init (already done)" >&2
fi

/opt/hub/docker/patch-sillytavern-config.sh
/opt/hub/docker/init-sillytavern-data.sh

echo "[sillytavern] launching server.js" >&2
exec node server.js \
  --listen \
  --port "${ST_PORT}" \
  --disableCsrf \
  --whitelist=false \
  --configPath "${ST_CONFIG}" \
  --dataRoot "${ST_DATA}/data"