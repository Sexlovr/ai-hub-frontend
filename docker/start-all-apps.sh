#!/usr/bin/env bash
# Start frontends. Default: lazy — only apps passed as args (or HUB_BOOT_APP).
# Set HUB_LAUNCH_MODE=always-on to run all three (needs ~16GB RAM; not for HF free).
set -uo pipefail

MODE="${HUB_LAUNCH_MODE:-lazy}"
BOOT_APP="${HUB_BOOT_APP:-sillytavern}"

wait_for() {
  local name="$1"
  local port="$2"
  local max="$3"
  for i in $(seq 1 "${max}"); do
    if (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1; then
      echo "[hub] ${name} ready on :${port} (after ${i}s)" >&2
      return 0
    fi
    sleep 1
  done
  echo "[hub] WARN: ${name} not ready on :${port} after ${max}s" >&2
  return 1
}

start_named() {
  local name="$1"
  /opt/hub/docker/start-one-app.sh "${name}" || return 1
  case "${name}" in
    sillytavern) wait_for sillytavern "${ST_PORT:-8000}" 120 ;;
    lumiverse)   wait_for lumiverse "${LUMIVERSE_PORT:-7861}" 90 ;;
    marinara)    wait_for marinara "${MARINARA_PORT:-7862}" 60 ;;
  esac
}

if [[ "${MODE}" == "always-on" ]]; then
  echo "[hub] always-on mode — starting all three backends" >&2
  start_named sillytavern || true
  /opt/hub/docker/start-one-app.sh lumiverse &
  p1=$!
  /opt/hub/docker/start-one-app.sh marinara &
  p2=$!
  wait "${p1}" "${p2}" 2>/dev/null || true
  wait_for lumiverse "${LUMIVERSE_PORT:-7861}" 90 || true
  wait_for marinara "${MARINARA_PORT:-7862}" 60 || true
  exit 0
fi

if [[ "$#" -gt 0 ]]; then
  for app in "$@"; do
    start_named "${app}" || true
  done
  exit 0
fi

echo "[hub] lazy mode — starting boot app only: ${BOOT_APP}" >&2
start_named "${BOOT_APP}" || true