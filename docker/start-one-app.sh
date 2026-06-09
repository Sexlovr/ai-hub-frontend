#!/usr/bin/env bash
# Start one frontend on demand (lazy mode — keeps HF CPU/RAM low).
set -uo pipefail

NAME="${1:-}"
DATA_ROOT="${DATA_ROOT:-/data}"
PID_DIR="${DATA_ROOT}/.pids"
LOG_DIR="${DATA_ROOT}/.logs"
mkdir -p "${PID_DIR}" "${LOG_DIR}"

if [[ -z "${NAME}" ]]; then
  echo "usage: start-one-app.sh <sillytavern|lumiverse|marinara>" >&2
  exit 1
fi

case "${NAME}" in
  sillytavern|lumiverse|marinara) ;;
  *) echo "unknown app: ${NAME}" >&2; exit 1 ;;
esac

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

PORT="$(port_for "${NAME}")"
SCRIPT="/opt/hub/docker/run-${NAME}.sh"
LOG="${LOG_DIR}/${NAME}.log"
PIDFILE="${PID_DIR}/${NAME}.pid"
LOGPIDFILE="${PID_DIR}/${NAME}-log.pid"

if port_up "${PORT}"; then
  echo "[hub] ${NAME} already up on :${PORT}" >&2
  exit 0
fi

if [[ ! -x "${SCRIPT}" ]]; then
  echo "[hub] ERROR: missing launcher ${SCRIPT}" >&2
  exit 1
fi

case "${NAME}" in
  lumiverse) /opt/hub/docker/ensure-lumiverse.sh 2>&1 || true ;;
  marinara)  /opt/hub/docker/ensure-marinara.sh 2>&1 || true ;;
esac

if [[ -f "${LOGPIDFILE}" ]]; then
  kill "$(cat "${LOGPIDFILE}")" 2>/dev/null || true
  rm -f "${LOGPIDFILE}"
fi
if [[ -f "${PIDFILE}" ]]; then
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
fi

: > "${LOG}"
# nice(10) keeps Node/Bun from pegging CPU during parallel HF workloads.
setsid bash -c "exec nice -n 10 bash \"${SCRIPT}\"" >> "${LOG}" 2>&1 &
echo $! > "${PIDFILE}"

tail -n 0 -f "${LOG}" 2>/dev/null | sed -u "s/^/[${NAME}] /" >&2 &
echo $! > "${LOGPIDFILE}"

echo "[hub] started ${NAME} pid $(cat "${PIDFILE}") on :${PORT}" >&2