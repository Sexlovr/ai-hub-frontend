#!/usr/bin/env bash
# Install Bun + Lumiverse on first open (not in Dockerfile — saves HF build CPU/RAM).
set -uo pipefail

DATA_ROOT="${DATA_ROOT:-/data}"
APP_ROOT="${LUMIVERSE_ROOT:-/data/lumiverse-app}"
MARKER="${DATA_ROOT}/lumiverse/.installed"

if [[ -f "${MARKER}" && -f "${APP_ROOT}/src/index.ts" ]]; then
  exit 0
fi

echo "[lumiverse] first-time install into ${APP_ROOT}…" >&2
mkdir -p "${DATA_ROOT}/lumiverse" "${APP_ROOT}"

if ! command -v bun >/dev/null 2>&1; then
  if [[ -x /usr/local/bin/bun ]]; then
    export PATH="/usr/local/bin:${PATH}"
  else
    echo "[lumiverse] installing bun…" >&2
    curl -fsSL https://bun.sh/install | bash
    export PATH="${HOME}/.bun/bin:/usr/local/bin:${PATH}"
    ln -sf "${HOME}/.bun/bin/bun" /usr/local/bin/bun 2>/dev/null || true
  fi
fi

export PATH="${HOME}/.bun/bin:/usr/local/bin:${PATH}"
bash /opt/hub/docker/install-lumiverse.sh 2>&1 || {
  echo "[lumiverse] install script failed" >&2
  exit 1
}

touch "${MARKER}" 2>/dev/null || true
echo "[lumiverse] install ready at ${APP_ROOT}" >&2