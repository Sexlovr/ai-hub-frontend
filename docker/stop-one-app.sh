#!/usr/bin/env bash
# Stop a single frontend (frees CPU/RAM on HF free tier).
set -uo pipefail

NAME="${1:-}"
DATA_ROOT="${DATA_ROOT:-/data}"
PID_DIR="${DATA_ROOT}/.pids"

if [[ -z "${NAME}" ]]; then
  echo "usage: stop-one-app.sh <sillytavern|lumiverse|marinara>" >&2
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

stop_pidfile() {
  local file="$1"
  local label="$2"
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  local pid
  pid="$(cat "${file}" 2>/dev/null || true)"
  if [[ -z "${pid}" ]]; then
    rm -f "${file}"
    return 0
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    echo "[hub] stopping ${label} pid ${pid}" >&2
    kill -TERM "${pid}" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  rm -f "${file}"
}

PORT="$(port_for "${NAME}")"
stop_pidfile "${PID_DIR}/${NAME}-log.pid" "${NAME} log"
stop_pidfile "${PID_DIR}/${NAME}.pid" "${NAME}"

if port_up "${PORT}"; then
  echo "[hub] WARN: ${NAME} still listening on :${PORT} after stop" >&2
  exit 1
fi

echo "[hub] ${NAME} stopped (:${PORT} free)" >&2