#!/usr/bin/env bash
set -uo pipefail

echo "[hub] HF start $(date -Is)" >&2
echo "[hub] launch=${HUB_LAUNCH_MODE:-lazy} boot=${HUB_BOOT_APP:-sillytavern} stop_idle=${HUB_STOP_IDLE:-1}" >&2
echo "[hub] ST_REPO_MODE=${ST_REPO_MODE:-1} ST_REF=${ST_REF:-1.18.0}" >&2

if [[ -z "${OWNER_PASSWORD:-}" && -z "${HUB_SYNC_PASSWORD:-}" ]]; then
  echo "[hub] WARN: OWNER_PASSWORD not set — Lumiverse sync skipped" >&2
fi

DATA_ROOT="${DATA_ROOT:-/data}"
export DATA_ROOT
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

if [[ -z "${PUBLIC_ORIGIN:-}" ]]; then
  resolved="$(bash /opt/hub/docker/resolve-public-origin.sh 2>/dev/null || true)"
  if [[ -n "${resolved}" ]]; then
    export PUBLIC_ORIGIN="${resolved}"
  fi
fi

mkdir -p "${DATA_ROOT}" "${DATA_ROOT}/.pids" \
  /tmp/nginx/body /tmp/nginx/proxy /tmp/nginx/fastcgi /tmp/nginx/uwsgi /tmp/nginx/scgi 2>/dev/null || true
chmod -R u+rwX "${DATA_ROOT}" /tmp/nginx 2>/dev/null || true

/opt/hub/docker/init-data-dirs.sh 2>&1 || echo "[hub] warn: init-data-dirs" >&2
/opt/hub/docker/link-shared-data.sh 2>&1 || true
/opt/hub/docker/init-sillytavern-data.sh 2>&1 || echo "[hub] warn: init-sillytavern-data" >&2

ACTIVE="${HUB_BOOT_APP:-sillytavern}"
if [[ -f "${DATA_ROOT}/.active_app" ]]; then
  saved="$(cat "${DATA_ROOT}/.active_app")"
  case "${saved}" in
    sillytavern|lumiverse|marinara) ACTIVE="${saved}" ;;
  esac
fi
echo "${ACTIVE}" > "${DATA_ROOT}/.active_app"

# Gateway binds :7860 immediately (HF health check). Backends warm in background.
echo "[hub] gateway-first boot — only ${ACTIVE} starts in background" >&2
/opt/hub/docker/start-one-app.sh "${ACTIVE}" >> "${DATA_ROOT}/.logs/boot.log" 2>&1 &

# Light periodic sync (10 min) — avoids CPU spikes from frequent work.
(while true; do sleep 600; /opt/hub/scripts/sync-shared-data.sh || true; done) >&2 &

# Deferred first sync once the active backend has had time to settle.
(
  sleep 90
  for attempt in 1 2 3; do
    if /opt/hub/scripts/sync-shared-data.sh 2>&1; then
      echo "[hub] post-boot sync ok (attempt ${attempt})" >&2
      break
    fi
    echo "[hub] post-boot sync retry ${attempt}/3 in 30s..." >&2
    sleep 30
  done
) >&2 &

echo "[hub] gateway on :${HUB_PORT:-7860} (lazy: one app at a time, idle apps stopped)" >&2
exec python3 /opt/hub/docker/hub-gateway.py