#!/usr/bin/env bash
# Resolve the public HTTPS origin for apps behind the HF reverse proxy.
# Prints one line: https://host (no trailing slash) or empty if unknown.

set -uo pipefail

origin="${PUBLIC_ORIGIN:-}"
if [[ -n "${origin}" ]]; then
  origin="${origin%/}"
  if [[ "${origin}" != http*://* ]]; then
    origin="https://${origin}"
  fi
  echo "${origin}"
  exit 0
fi

if [[ -n "${SPACE_HOST:-}" ]]; then
  host="${SPACE_HOST#https://}"
  host="${host#http://}"
  host="${host%/}"
  echo "https://${host}"
  exit 0
fi

if [[ -n "${SPACE_ID:-}" ]]; then
  # SPACE_ID is "owner/name" → https://owner-name.hf.space
  host="${SPACE_ID/\//-}.hf.space"
  echo "https://${host}"
  exit 0
fi

exit 0