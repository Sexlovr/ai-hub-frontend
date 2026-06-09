#!/usr/bin/env bash
# One-time image setup at first boot (keeps Dockerfile thin for HF builds).
set -uo pipefail

MARKER="${HUB_SETUP_MARKER:-/data/.hub-image-setup-done}"
DATA_ROOT="${DATA_ROOT:-/data}"

if [[ -f "${MARKER}" ]]; then
  echo "[hub] bootstrap already done" >&2
  exit 0
fi

echo "[hub] first-boot bootstrap (patches, permissions)…" >&2
mkdir -p "${DATA_ROOT}" "${DATA_ROOT}/.logs" "${DATA_ROOT}/.pids" 2>/dev/null || true

chmod +x /opt/hub/docker/*.sh /opt/hub/scripts/*.sh 2>/dev/null || true
chmod +x /opt/hub/docker/start-all-apps.sh \
  /opt/hub/docker/start-one-app.sh \
  /opt/hub/docker/stop-one-app.sh \
  /opt/hub/overlays/sillytavern/patches/apply-patches.sh 2>/dev/null || true

if [[ -f /opt/hub/public/index.html ]]; then
  cp /opt/hub/public/index.html /opt/hub/public/hub.html 2>/dev/null || true
fi

echo 'upstream active_backend { server 127.0.0.1:8000; }' > /opt/hub/docker/upstream.conf 2>/dev/null || true

ST_ROOT="/apps/sillytavern"
if [[ -d "${ST_ROOT}" ]]; then
  touch "${ST_ROOT}/.hub-built" 2>/dev/null || true
  ST_ROOT="${ST_ROOT}" OVERLAY=/opt/hub/overlays/sillytavern \
    bash /opt/hub/overlays/sillytavern/patches/apply-patches.sh 2>&1 || true
fi

# SPA subpath patches — only when app trees exist (lumiverse may install on first open).
if [[ -d /apps/lumiverse ]]; then
  /opt/hub/docker/patch-lumiverse-auth.sh 2>&1 || true
  /opt/hub/docker/patch-lumiverse-sw.sh 2>&1 || true
fi
if [[ -d /apps/marinara ]]; then
  /opt/hub/docker/patch-marinara-sw.sh 2>&1 || true
fi
if [[ -d /apps/lumiverse ]] || [[ -d /apps/marinara ]]; then
  /opt/hub/docker/patch-app-subpaths.sh 2>&1 || true
fi

touch "${MARKER}" 2>/dev/null || true
echo "[hub] bootstrap complete" >&2