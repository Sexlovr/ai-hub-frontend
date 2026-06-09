#!/usr/bin/env bash
# Apply hub-owned SillyTavern overlays (repo controls ST — no fork, no git clone).
set -euo pipefail

ST_ROOT="${ST_ROOT:-/apps/sillytavern}"
OVERLAY="${OVERLAY:-/opt/hub/overlays/sillytavern}"
MARKER="${ST_ROOT}/.hub-overlay-applied"
OVERLAY_VER="$(head -1 "${OVERLAY}/VERSION" 2>/dev/null || echo unknown)"

if [[ ! -d "${ST_ROOT}" ]]; then
  echo "[hub] ST overlay skip — missing ${ST_ROOT}" >&2
  exit 0
fi

if [[ -f "${MARKER}" ]] && grep -qF "${OVERLAY_VER}" "${MARKER}" 2>/dev/null; then
  echo "[hub] ST overlay ${OVERLAY_VER} already applied" >&2
  exit 0
fi

echo "[hub] applying ST overlay ${OVERLAY_VER} from ${OVERLAY}" >&2

if [[ -d "${OVERLAY}/public" ]]; then
  rsync -a "${OVERLAY}/public/" "${ST_ROOT}/public/" 2>/dev/null || \
    cp -a "${OVERLAY}/public/." "${ST_ROOT}/public/" 2>/dev/null || true
  mkdir -p "${ST_ROOT}/scripts"
  if [[ -f "${OVERLAY}/public/hub-sw-bust.js" ]]; then
    cp "${OVERLAY}/public/hub-sw-bust.js" "${ST_ROOT}/scripts/hub-sw-bust.js"
  fi
fi

INDEX="${ST_ROOT}/public/index.html"
if [[ -f "${INDEX}" ]] && ! grep -q 'hub-sw-bust.js' "${INDEX}"; then
  python3 - "${INDEX}" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
inject = '  <script src="/scripts/hub-sw-bust.js"></script>\n'
head = re.search(r"</head>", text, re.I)
if head:
    text = text[: head.start()] + inject + text[head.start() :]
else:
    text = inject + text
path.write_text(text, encoding="utf-8")
print("[hub] injected hub-sw-bust.js into ST index.html", flush=True)
PY
fi

{
  echo "${OVERLAY_VER}"
  echo "hub-overlay-$(date -u +%Y%m%d)"
  cat "${OVERLAY}/VERSION" 2>/dev/null || true
} > "${ST_ROOT}/.hub-build-id"

echo "${OVERLAY_VER}" > "${MARKER}"
echo "[hub] ST overlay applied (${OVERLAY_VER})" >&2