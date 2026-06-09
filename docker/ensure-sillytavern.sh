#!/usr/bin/env bash
# Install SillyTavern on first open — never at HF Docker build time.
set -uo pipefail

DATA_ROOT="${DATA_ROOT:-/data}"
ST_ROOT="${ST_INSTALL_ROOT:-/data/st-app}"
MARKER="${DATA_ROOT}/sillytavern/.st-installed"

if [[ -f "${MARKER}" && -f "${ST_ROOT}/server.js" ]]; then
  exit 0
fi

echo "[sillytavern] first-time install to ${ST_ROOT} (CPU spike only now, not at HF build)…" >&2
mkdir -p "${DATA_ROOT}/sillytavern"

export ST_ROOT
export HUB_ROOT="${HUB_ROOT:-/opt/hub}"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=2048}"

if [[ -x /opt/hub/docker/build-sillytavern.sh ]]; then
  bash /opt/hub/docker/build-sillytavern.sh 2>&1
else
  echo "[sillytavern] ERROR: build-sillytavern.sh missing — hub files not installed" >&2
  exit 1
fi

touch "${MARKER}" 2>/dev/null || true
echo "[sillytavern] install complete at ${ST_ROOT}" >&2