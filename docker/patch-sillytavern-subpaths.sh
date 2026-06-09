#!/usr/bin/env bash
# Bake /apps/sillytavern/ into SillyTavern client bundles at image build time.
# Server routes stay at /api/* — only browser-facing HTML/JS/CSS/JSON are patched.
set -euo pipefail

ST_ROOT="/apps/sillytavern"
PREFIX="/apps/sillytavern"
MARKER="${ST_ROOT}/.hub-subpath-patched"
LOCK="${ST_ROOT}/.hub-subpath-patch.lock"

if [[ ! -d "${ST_ROOT}" ]]; then
  echo "[hub] skip sillytavern subpath patch — missing ${ST_ROOT}" >&2
  exit 0
fi

if [[ -f "${MARKER}" ]]; then
  echo "[hub] sillytavern subpath patch already applied — skip" >&2
  exit 0
fi

exec 9>"${LOCK}"
if ! flock -n 9; then
  echo "[hub] sillytavern subpath patch already running — skip" >&2
  exit 0
fi

python3 - "${ST_ROOT}" "${PREFIX}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
prefix = sys.argv[2].rstrip("/")
hub_api = (
    "/api/hub",
    "/api/active",
    "/api/ready",
    "/api/debug",
    "/api/sync",
)

SKIP_DIRS = {
    "node_modules",
    ".git",
    "data",
    "config",
    "plugins",
    "default",
    "tests",
    "dist",
    "build",
    "coverage",
}

# Never patch the Node server — only static assets the browser loads.
SKIP_FILES = {
    "server.js",
    "lib.js",
    "webpack.config.js",
    "postcss.config.js",
    "babel.config.js",
}


def skip_path(path: str) -> bool:
    return path.startswith(prefix + "/") or path.startswith("//") or any(
        path.startswith(h) for h in hub_api
    )


def rewrite_static(text: str) -> str:
    def repl_quoted(match: re.Match[str]) -> str:
        quote, path = match.group(1), match.group(2)
        if skip_path(path):
            return match.group(0)
        return f"{quote}{prefix}{path}{quote}"

    def repl_backtick(match: re.Match[str]) -> str:
        path = match.group(1)
        if not path.startswith("/") or skip_path(path):
            return match.group(0)
        return f"`{prefix}{path}`"

    text = re.sub(r'(["\'])(/(?!/)[^"\'\\]*)\1', repl_quoted, text)
    text = re.sub(r"`(/(?!/)[^`\\]+)`", repl_backtick, text)
    text = re.sub(
        r'(\bimport\s*\(\s*)(["\'])(/(?!/)[^"\'\\]*)\2',
        lambda m: (
            f"{m.group(1)}{m.group(2)}{prefix}{m.group(3)}{m.group(2)}"
            if not skip_path(m.group(3))
            else m.group(0)
        ),
        text,
    )
    text = re.sub(
        r'(\bnew URL\s*\(\s*)(["\'])(/(?!/)[^"\'\\]*)\2',
        lambda m: (
            f"{m.group(1)}{m.group(2)}{prefix}{m.group(3)}{m.group(2)}"
            if not skip_path(m.group(3))
            else m.group(0)
        ),
        text,
    )
    return text


def fix_base_href(text: str) -> str:
    tag = f'<base href="{prefix}/">'
    if re.search(r"<base\s", text, re.I):
        return re.sub(
            r"<base\s+href=[\"'][^\"']*[\"']\s*/?\s*>",
            tag,
            text,
            count=1,
            flags=re.I,
        )
    head = re.search(r"<head([^>]*)>", text, re.I)
    if head:
        pos = head.end()
        return text[:pos] + f"\n  {tag}" + text[pos:]
    return tag + text


def should_patch(path: Path) -> bool:
    if any(part in SKIP_DIRS for part in path.parts):
        return False
    if path.name in SKIP_FILES:
        return False
    # src/ is mostly server code; allow client modules under src/endpoints only.
    if "src" in path.parts and "endpoints" not in path.parts:
        return False
    name = path.name.lower()
    return name.endswith((".html", ".css", ".json", ".js", ".mjs", ".webmanifest"))


changed = 0
for path in root.rglob("*"):
    if not path.is_file() or not should_patch(path):
        continue
    try:
        original = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    text = original
    if path.name.lower().endswith(".html"):
        text = fix_base_href(text)
    text = rewrite_static(text)
    if text != original:
        path.write_text(text, encoding="utf-8")
        changed += 1

print(f"[hub] sillytavern subpath patch prefix={prefix}/ files_changed={changed}", flush=True)
PY

touch "${MARKER}"