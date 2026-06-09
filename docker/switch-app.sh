#!/usr/bin/env bash
# Switch active frontend — lazy mode: stop idle apps, start only the target.
set -uo pipefail

APP="${1:-}"
DATA_ROOT="${DATA_ROOT:-/data}"
LOCK_FILE="${DATA_ROOT}/.switch.lock"
STOP_IDLE="${HUB_STOP_IDLE:-1}"

if [[ -z "${APP}" ]]; then
  echo "usage: switch-app.sh <sillytavern|lumiverse|marinara>" >&2
  exit 1
fi

case "${APP}" in
  sillytavern|lumiverse|marinara) ;;
  *) echo "unknown app: ${APP}" >&2; exit 1 ;;
esac

PREV_APP=""
if [[ -f "${DATA_ROOT}/.active_app" ]]; then
  PREV_APP="$(cat "${DATA_ROOT}/.active_app")"
fi

echo "${APP}" > "${DATA_ROOT}/.active_app"
echo "[hub] routing → ${APP}" >&2

if [[ "${HUB_ROUTING_ONLY:-}" == "1" ]]; then
  exit 0
fi

exec 9>"${LOCK_FILE}"
if ! flock -w 15 9; then
  echo "[hub] sync queue busy — routing already ${APP}" >&2
  exit 0
fi

port_for() {
  case "$1" in
    sillytavern) echo "${ST_PORT:-8000}" ;;
    lumiverse)   echo "${LUMIVERSE_PORT:-7861}" ;;
    marinara)    echo "${MARINARA_PORT:-7862}" ;;
  esac
}

port_up() {
  local port="$1"
  (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1
}

PORT="$(port_for "${APP}")"

if [[ -n "${PREV_APP}" && "${PREV_APP}" != "${APP}" ]]; then
  HUB_SYNC_EXPORT="${PREV_APP}" python3 /opt/hub/scripts/hub-sync-import.py 2>&1 || true
fi

if [[ "${STOP_IDLE}" == "1" ]]; then
  for other in sillytavern lumiverse marinara; do
    if [[ "${other}" != "${APP}" ]]; then
      /opt/hub/docker/stop-one-app.sh "${other}" 2>&1 || true
    fi
  done
fi

/opt/hub/docker/start-one-app.sh "${APP}" 2>&1 || true

if ! port_up "${PORT}"; then
  for i in $(seq 1 90); do
    if port_up "${PORT}"; then
      break
    fi
    sleep 1
  done
fi

if ! port_up "${PORT}"; then
  echo "[hub] ERROR: ${APP} not listening on :${PORT}" >&2
  exit 1
fi

cat > /opt/hub/docker/upstream.conf <<EOF
upstream active_backend {
    server 127.0.0.1:${PORT};
}
EOF

if [[ "${HUB_SKIP_SYNC:-}" != "1" ]]; then
  /opt/hub/scripts/sync-shared-data.sh 2>&1 || echo "[hub] warn: sync-shared-data" >&2
fi

echo "[hub] switched to ${APP} on :${PORT} (lazy, idle stopped=${STOP_IDLE})" >&2