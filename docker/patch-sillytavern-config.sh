#!/usr/bin/env bash
# Apply AFTER npm run init — init merges defaults that re-enable blocking.
set -uo pipefail

DATA_ROOT="${DATA_ROOT:-/data}"
CONFIG="${DATA_ROOT}/sillytavern/config/config.yaml"

[[ -f "${CONFIG}" ]] || cp /opt/hub/config/sillytavern-config.yaml "${CONFIG}"

python3 - "${CONFIG}" <<'PY'
import pathlib, re, sys

p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding="utf-8")

def sub_flag(key: str, value: str) -> None:
    global text
    text, n = re.subn(rf"(?m)^{re.escape(key)}:.*$", f"{key}: {value}", text)
    if n == 0:
        text += f"\n{key}: {value}\n"

sub_flag("listen", "true")
sub_flag("whitelistMode", "false")
sub_flag("enableForwardedWhitelist", "false")
sub_flag("disableCsrfProtection", "true")
sub_flag("securityOverride", "true")
sub_flag("skipContentCheck", "true")

# hostWhitelist block
if re.search(r"(?m)^hostWhitelist:", text):
    text = re.sub(r"(?m)^  enabled:.*$", "  enabled: false", text, count=1)
    text = re.sub(r"(?m)^  scan:.*$", "  scan: false", text, count=1)
else:
    text += "\nhostWhitelist:\n  enabled: false\n  scan: false\n  hosts: []\n"

p.write_text(text, encoding="utf-8")
print("[hub] SillyTavern config patched (host + IP whitelist off)", flush=True)
PY