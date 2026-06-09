#!/usr/bin/env python3
"""HF public gateway on :7860 — SillyTavern at /, Lumiverse/Marinara at /apps/{name}/."""
from __future__ import annotations

import gzip
import http.client
import json
import os
import re
import select
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

DATA_ROOT = Path(os.environ.get("DATA_ROOT", "/data"))
PUBLIC = Path("/opt/hub/public")
SYNC_SCRIPT = "/opt/hub/scripts/sync-shared-data.sh"
SWITCH_SCRIPT = "/opt/hub/docker/switch-app.sh"
ACTIVE_FILE = DATA_ROOT / ".active_app"
HUB_PORT = int(os.environ.get("HUB_PORT", "7860"))
LAZY_LAUNCH = os.environ.get("HUB_LAUNCH_MODE", "lazy") != "always-on"
_lazy_lock = threading.Lock()
_lazy_inflight: set[str] = set()

PORTS = {
    "sillytavern": int(os.environ.get("ST_PORT", "8000")),
    "lumiverse": int(os.environ.get("LUMIVERSE_PORT", "7861")),
    "marinara": int(os.environ.get("MARINARA_PORT", "7862")),
}

# SillyTavern is served at / (native paths). Only Vite SPAs need subpath prefixes.
APP_PREFIXES = {
    "lumiverse": "/apps/lumiverse",
    "marinara": "/apps/marinara",
}

HUB_ONLY_PATHS = {
    "/api/hub",
    "/api/hub/",
    "/api/active",
    "/api/ready",
    "/api/debug",
    "/api/sync",
    "/api/health/st",
    "/hub",
    "/hub/",
    "/hub.html",
    "/hub/favicon.ico",
}

ST_BUILD_ID_FILE = Path("/apps/sillytavern/.hub-build-id")
ST_OVERLAY_VERSION = Path("/opt/hub/overlays/sillytavern/VERSION")

# Root-level paths Vite SPAs still request without Referer (dynamic import / PWA).
ORPHAN_APP_PATH_PREFIXES = (
    "/assets/",
    "/logo-",
    "/icon-",
    "/manifest",
    "/registerSW.js",
)

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}

SKIP_REQUEST_HEADERS = {
    "host",
    "connection",
    "content-length",
    "transfer-encoding",
    "accept-encoding",
    # Avoid 304 revalidation serving pre-v10 poisoned cached bodies in browsers.
    "if-none-match",
    "if-modified-since",
}

SKIP_RESPONSE_CACHE_HEADERS = {
    "cache-control",
    "etag",
    "last-modified",
    "expires",
}

MAX_JS_REWRITE_BYTES = int(os.environ.get("MAX_JS_REWRITE_BYTES", "524288"))

# Markers that build-time patch scripts (docker/patch-app-subpaths.sh) have run.
BUILD_PATCH_MARKERS: dict[str, tuple[str, ...]] = {
    "lumiverse": ("qs=`/apps/lumiverse/api/v1`", "basename:e=`/apps/lumiverse`"),
    "marinara": ("qs=`/apps/marinara/api/v1`", 'const At="/apps/marinara/api"', "basename:e=`/apps/marinara`"),
}


def active_app() -> str:
    if ACTIVE_FILE.is_file():
        name = ACTIVE_FILE.read_text(encoding="utf-8").strip().lower()
        if name in PORTS:
            return name
    return "sillytavern"


def backend_port(app: str) -> int:
    return PORTS.get(app, PORTS["sillytavern"])


def port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def sillytavern_deep_ready() -> bool:
    port = PORTS["sillytavern"]
    if not port_open(port):
        return False
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request(
            "GET",
            "/api/settings/get",
            headers={"Accept": "application/json", "User-Agent": "hub-ready-probe"},
        )
        resp = conn.getresponse()
        resp.read()
        return 200 <= resp.status < 500
    except Exception:
        return False


def queue_backend_start(app: str) -> None:
    if app not in PORTS:
        return
    with _lazy_lock:
        if app in _lazy_inflight:
            return
        _lazy_inflight.add(app)

    def _run() -> None:
        env = os.environ.copy()
        env["HUB_SKIP_SYNC"] = "1"
        try:
            subprocess.run(
                [SWITCH_SCRIPT, app],
                capture_output=True,
                text=True,
                timeout=600,
                check=False,
                env=env,
            )
        except Exception as exc:
            print(f"[gateway] lazy start {app} failed: {exc}", flush=True)
        finally:
            with _lazy_lock:
                _lazy_inflight.discard(app)

    threading.Thread(target=_run, daemon=True, name=f"start-{app}").start()


def ensure_backend(app: str) -> bool:
    if backend_ready(app):
        return True
    if LAZY_LAUNCH:
        queue_backend_start(app)
    return False


def backend_ready(app: str) -> bool:
    port = PORTS.get(app)
    if port is None or not port_open(port):
        return False
    if app == "sillytavern":
        return sillytavern_deep_ready()
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        conn.request("GET", "/", headers={"Accept": "text/html,application/json", "User-Agent": "hub-ready-probe"})
        resp = conn.getresponse()
        resp.read()
        return 200 <= resp.status < 500
    except Exception:
        return port_open(port)


def st_build_info() -> dict[str, str]:
    info: dict[str, str] = {
        "repo_mode": os.environ.get("ST_REPO_MODE", "1"),
        "st_ref": os.environ.get("ST_REF", "unknown"),
    }
    if ST_BUILD_ID_FILE.is_file():
        info["build_id"] = ST_BUILD_ID_FILE.read_text(encoding="utf-8").strip().splitlines()[0]
    if ST_OVERLAY_VERSION.is_file():
        info["overlay"] = ST_OVERLAY_VERSION.read_text(encoding="utf-8").strip().splitlines()[0]
    return info


def app_from_referer(referer: str) -> str | None:
    if not referer:
        return None
    for app, prefix in APP_PREFIXES.items():
        if f"{prefix}/" in referer or referer.rstrip("/").endswith(prefix):
            return app
    return None


def app_from_origin(origin: str) -> str | None:
    if not origin:
        return None
    origin = origin.rstrip("/")
    for app, prefix in APP_PREFIXES.items():
        if origin.endswith(prefix):
            return app
    return None


def app_from_cookie(cookie_header: str) -> str | None:
    if not cookie_header:
        return None
    for part in cookie_header.split(";"):
        part = part.strip()
        if part.startswith("hub_app="):
            app = part.split("=", 1)[1].strip().lower()
            if app in PORTS:
                return app
    return None


HUB_API_PREFIXES = ("/api/hub", "/api/active", "/api/ready", "/api/debug", "/api/sync")


def decompress_body(data: bytes, encoding: str | None) -> tuple[bytes, bool]:
    """Decompress backend body when possible. Returns (body, was_decompressed)."""
    if not encoding:
        return data, False

    enc = encoding.lower()
    if "gzip" in enc or enc == "x-gzip":
        try:
            return gzip.decompress(data), True
        except OSError:
            return data, False

    if "br" in enc:
        try:
            import brotli  # type: ignore[import-not-found]

            return brotli.decompress(data), True
        except Exception:
            return data, False

    if "deflate" in enc:
        try:
            import zlib

            return zlib.decompress(data), True
        except Exception:
            return data, False

    return data, False


def fix_base_href(text: str, prefix: str) -> str:
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


def _skip_path(path: str, prefix: str) -> bool:
    return path.startswith(prefix + "/") or path.startswith("//") or any(
        path.startswith(h) for h in HUB_API_PREFIXES
    )


def strip_lumiverse_pwa_html(text: str) -> str:
    """Remove inline PWA registration — stale SW breaks subpath loading."""
    text = re.sub(
        r"<script[^>]*vite-plugin-pwa[^>]*>.*?</script>",
        "<!-- hub: lumiverse PWA removed -->",
        text,
        flags=re.DOTALL | re.IGNORECASE,
    )
    return text


def rewrite_root_paths(text: str, prefix: str) -> str:
    """Rewrite root-absolute URLs in HTML/CSS/JSON — <base> does NOT affect paths starting with /."""

    def repl_quoted(match: re.Match[str]) -> str:
        quote, path = match.group(1), match.group(2)
        if _skip_path(path, prefix):
            return match.group(0)
        return f"{quote}{prefix}{path}{quote}"

    def repl_backtick(match: re.Match[str]) -> str:
        path = match.group(1)
        if not path.startswith("/") or _skip_path(path, prefix):
            return match.group(0)
        return f"`{prefix}{path}`"

    text = re.sub(r'(["\'])(/(?!/)[^"\'\\]*)\1', repl_quoted, text)
    text = re.sub(r"`(/(?!/)[^`\\]+)`", repl_backtick, text)
    text = re.sub(
        r'(\bimport\s*\(\s*)(["\'])(/(?!/)[^"\'\\]*)\2',
        lambda m: (
            f"{m.group(1)}{m.group(2)}{prefix}{m.group(3)}{m.group(2)}"
            if not _skip_path(m.group(3), prefix)
            else m.group(0)
        ),
        text,
    )
    text = re.sub(
        r'(\bnew URL\s*\(\s*)(["\'])(/(?!/)[^"\'\\]*)\2',
        lambda m: (
            f"{m.group(1)}{m.group(2)}{prefix}{m.group(3)}{m.group(2)}"
            if not _skip_path(m.group(3), prefix)
            else m.group(0)
        ),
        text,
    )
    return text


def strip_erroneous_app_prefix(text: str, prefix: str) -> str:
    """Undo legacy v5 gateway rewriting of API endpoint suffixes in JS bundles."""

    def repl_quoted(match: re.Match[str]) -> str:
        quote, path = match.group(1), match.group(2)
        if not path.startswith(prefix + "/") or path.startswith(prefix + "/api/"):
            return match.group(0)
        return f"{quote}{path[len(prefix):]}{quote}"

    return re.sub(r'(["\'])(/[^"\'\\]+)\1', repl_quoted, text)


def rewrite_js_api_paths(text: str, prefix: str) -> str:
    """Rewrite only /api* URLs in JS.

    Do NOT prefix bare endpoint suffixes like "/chats" — Marinara composes
    fetch(`${API_BASE}${endpoint}`) and double-prefixing breaks every API call.
    """
    text = strip_erroneous_app_prefix(text, prefix)

    def repl_quoted(match: re.Match[str]) -> str:
        quote, path = match.group(1), match.group(2)
        if not path.startswith("/api") or _skip_path(path, prefix):
            return match.group(0)
        return f"{quote}{prefix}{path}{quote}"

    def repl_backtick(match: re.Match[str]) -> str:
        path = match.group(1)
        if not path.startswith("/api") or _skip_path(path, prefix):
            return match.group(0)
        return f"`{prefix}{path}`"

    text = text.replace('const At="/api"', f'const At="{prefix}/api"')
    text = text.replace("const At='/api'", f"const At='{prefix}/api'")
    text = text.replace("qs=`/api/v1`", f"qs=`{prefix}/api/v1`")
    text = re.sub(r'(["\'])(/api[^"\'\\]*)\1', repl_quoted, text)
    text = re.sub(r"`(/api[^`\\]*)`", repl_backtick, text)
    text = re.sub(
        r'(\bimport\s*\(\s*)(["\'])(/api[^"\'\\]*)\2',
        lambda m: (
            f"{m.group(1)}{m.group(2)}{prefix}{m.group(3)}{m.group(2)}"
            if not _skip_path(m.group(3), prefix)
            else m.group(0)
        ),
        text,
    )
    text = re.sub(
        r'(\bnew URL\s*\(\s*)(["\'])(/api[^"\'\\]*)\2',
        lambda m: (
            f"{m.group(1)}{m.group(2)}{prefix}{m.group(3)}{m.group(2)}"
            if not _skip_path(m.group(3), prefix)
            else m.group(0)
        ),
        text,
    )
    return text


def js_already_build_patched(text: str, app: str) -> bool:
    markers = BUILD_PATCH_MARKERS.get(app)
    if not markers:
        return False
    return any(marker in text for marker in markers)


def patch_lumiverse_router_basename(text: str, prefix: str) -> str:
    """React Router defaults to basename=/ — routes fail under /apps/lumiverse/."""
    marker = f"basename:e=`{prefix}`"
    if marker in text:
        return text
    replacements = (
        ("basename:e=`/`", marker),
        ("e.basename||`/`", f"e.basename||`{prefix}`"),
        ("S=e.basename||`/`", f"S=e.basename||`{prefix}`"),
        ("c=e.basename||`/`", f"c=e.basename||`{prefix}`"),
    )
    for old, new in replacements:
        text = text.replace(old, new)
    return text


def patch_lumiverse_js(text: str, prefix: str) -> str:
    """Apply basename + /api* prefixing for Lumiverse entry/lazy chunks."""
    text = patch_lumiverse_router_basename(text, prefix)
    api_marker = f"qs=`{prefix}/api/v1`"
    if api_marker not in text:
        text = rewrite_js_api_paths(text, prefix)
        # Interpolated CSS url() templates: url(${q}/api/v1/theme-assets/...)
        text = text.replace("/api/v1/theme-assets", f"{prefix}/api/v1/theme-assets")
        text = text.replace("/api/v1/image-gen", f"{prefix}/api/v1/image-gen")
    return text


def rewrite_app_body(data: bytes, content_type: str, prefix: str, app: str = "") -> bytes:
    if not prefix:
        return data
    ct = content_type.lower()
    if not any(
        token in ct
        for token in ("text/html", "javascript", "text/css", "json", "manifest")
    ):
        return data
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return data
    if "javascript" in ct:
        # Vite/Marinara/Lumiverse bundles are patched at image build — do not
        # re-decode multi-MB chunks on every request (slow + risks corruption).
        if app in ("lumiverse", "marinara") and js_already_build_patched(text, app):
            return data
        if app == "lumiverse":
            patched = patch_lumiverse_js(text, prefix)
            if patched != text:
                return patched.encode("utf-8")
            return data
        if js_already_build_patched(text, app):
            return data
        if len(data) > MAX_JS_REWRITE_BYTES:
            return data
        text = rewrite_js_api_paths(text, prefix)
    else:
        if "text/html" in ct:
            text = fix_base_href(text, prefix)
            if app == "lumiverse":
                text = strip_lumiverse_pwa_html(text)
        text = rewrite_root_paths(text, prefix)
    return text.encode("utf-8")


def proxy_cache_headers(app: str, content_type: str) -> dict[str, str]:
    """Override backend cache headers for subpath SPAs (avoid stale gzip in browser cache)."""
    ct = content_type.lower()
    if "javascript" in ct:
        return {"Cache-Control": "no-cache"}
    return {}


def rewrite_location(location: str, prefix: str) -> str:
    if not location.startswith("/") or location.startswith("//"):
        return location
    if location == prefix or location.startswith(prefix + "/"):
        return location
    return prefix + location


def resolve_route(
    path: str,
    referer: str,
    query: str = "",
    origin: str = "",
    cookie: str = "",
) -> tuple[str, str]:
    """Return (app_name, backend_path)."""
    for app, prefix in APP_PREFIXES.items():
        if path == prefix:
            return app, "/"
        if path.startswith(prefix + "/"):
            return app, path[len(prefix) :] or "/"

    context_app = (
        app_from_referer(referer)
        or app_from_origin(origin)
        or app_from_cookie(cookie)
    )
    if context_app and (
        any(path.startswith(prefix) for prefix in ORPHAN_APP_PATH_PREFIXES)
        or path == "/manifest.webmanifest"
    ):
        return context_app, path

    # SillyTavern owns / and all root paths not claimed by hub or subpath SPAs.
    return "sillytavern", path


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "hub-gateway/18"

    def log_message(self, fmt: str, *args) -> None:
        print(f"[gateway] {self.address_string()} - {fmt % args}", flush=True)

    def _parsed(self) -> tuple[str, str, str]:
        parsed = urlparse(self.path)
        return parsed.path or "/", parsed.query, self.headers.get("Referer", "")

    def _send_bytes(self, code: int, body: bytes, content_type: str, extra_headers: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, code: int, payload: dict) -> None:
        self._send_bytes(code, json.dumps(payload).encode("utf-8"), "application/json")

    def _send_html(self, filename: str, cache_control: str = "no-cache") -> None:
        path = PUBLIC / filename
        if not path.is_file():
            self._send_json(404, {"error": f"{filename} missing"})
            return
        self._send_bytes(
            200,
            path.read_bytes(),
            "text/html; charset=utf-8",
            {"Cache-Control": cache_control},
        )

    def _send_public_file(self, filename: str, content_type: str) -> None:
        path = PUBLIC / filename
        if not path.is_file():
            self._send_json(404, {"error": f"{filename} missing"})
            return
        self._send_bytes(
            200,
            path.read_bytes(),
            content_type,
            {"Cache-Control": "public, max-age=86400"},
        )

    def _redirect(self, location: str) -> None:
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _run_sync_background(self, phase: str = "") -> None:
        env = os.environ.copy()
        if phase:
            env["HUB_SYNC_PHASE"] = phase
        try:
            subprocess.run(
                [SYNC_SCRIPT],
                capture_output=True,
                text=True,
                timeout=300,
                check=False,
                env=env,
            )
        except Exception as exc:
            print(f"[gateway] background sync failed: {exc}", flush=True)

    def _handle_hub_route(self, method: str) -> bool:
        path, query, _referer = self._parsed()

        if path in HUB_ONLY_PATHS:
            if path in {"/api/hub", "/api/hub/", "/hub/", "/hub.html"}:
                filename = "hub.html" if path == "/hub.html" else "index.html"
                self._send_html(filename)
                return True
            if path == "/hub":
                self._send_html("hub-redirect.html")
                return True

        if path == "/api/active":
            apps = {"sillytavern": "/"}
            apps.update(APP_PREFIXES)
            self._send_json(
                200,
                {
                    "active": active_app(),
                    "routing": "st-root+subpath-spas",
                    "hub_launcher": "/hub",
                    "apps": apps,
                },
            )
            return True

        if path == "/api/ready":
            probes = {name: backend_ready(name) for name in PORTS}
            self._send_json(
                200,
                {
                    "routing": "st-root+subpath-spas",
                    "launch_mode": "lazy" if LAZY_LAUNCH else "always-on",
                    "ready": probes,
                    "active": active_app(),
                    "st_settings_ok": sillytavern_deep_ready(),
                },
            )
            return True

        if path == "/api/health/st":
            self._send_json(
                200,
                {
                    "port_open": port_open(PORTS["sillytavern"]),
                    "settings_ok": sillytavern_deep_ready(),
                    "build": st_build_info(),
                },
            )
            return True

        if path == "/api/debug":
            probes = {}
            for name, port in PORTS.items():
                probes[name] = {
                    "port": port,
                    "prefix": APP_PREFIXES.get(name, "/"),
                    "port_open": port_open(port),
                    "http_ready": backend_ready(name),
                }
            probes["sillytavern"]["settings_ok"] = sillytavern_deep_ready()
            probes["sillytavern"]["build"] = st_build_info()
            shared_chars = DATA_ROOT / "shared" / "characters"
            hub_cards = sorted(
                p.name
                for p in shared_chars.glob("hub_*.png")
                if p.is_file()
            ) if shared_chars.is_dir() else []
            sync_state = DATA_ROOT / ".hub-sync" / "import-state.json"
            sync_hint = {
                "owner_password_set": bool(
                    os.environ.get("OWNER_PASSWORD") or os.environ.get("HUB_SYNC_PASSWORD")
                ),
                "lumiverse_import_requires": "OWNER_PASSWORD in HF Secrets (Lumiverse login password)",
                "canonical_cards": hub_cards,
                "st_storage": str(DATA_ROOT / "sillytavern" / "data" / "default-user"),
                "lumiverse_storage": str(DATA_ROOT / "lumiverse"),
                "marinara_storage": str(DATA_ROOT / "marinara"),
                "sync_state_file": str(sync_state) if sync_state.is_file() else None,
            }
            self._send_json(
                200,
                {
                    "routing": "ST at / ; lumiverse+marinara at /apps/{app}/",
                    "gateway_version": self.server_version,
                    "hub_launcher": "/hub",
                    "active_fallback": active_app(),
                    "apps": probes,
                    "shared_characters": str(shared_chars),
                    "sync": sync_hint,
                },
            )
            return True

        if path == "/api/sync" and method == "GET":
            _, query, _ = self._parsed()
            phase = ""
            if query:
                for part in query.split("&"):
                    if part.startswith("phase="):
                        phase = part.split("=", 1)[1].strip()
                        break
            threading.Thread(
                target=self._run_sync_background,
                args=(phase,),
                daemon=True,
            ).start()
            self._send_json(
                200,
                {"ok": True, "message": "sync started in background", "phase": phase or "all"},
            )
            return True

        if path == "/hub/favicon.ico" and method == "GET":
            self._send_public_file("favicon.ico", "image/x-icon")
            return True

        # Legacy shortcuts → canonical app URLs.
        legacy = {
            "/sillytavern": "/",
            "/sillytavern/": "/",
            "/apps/sillytavern": "/",
            "/apps/sillytavern/": "/",
            "/lumiverse": "/apps/lumiverse/",
            "/lumiverse/": "/apps/lumiverse/",
            "/marinara": "/apps/marinara/",
            "/marinara/": "/apps/marinara/",
        }
        if path in legacy:
            self._redirect(legacy[path])
            return True

        if path.startswith("/apps/sillytavern/"):
            self._redirect(path[len("/apps/sillytavern") :] or "/")
            return True

        if path.startswith("/api/switch/") and method == "GET":
            app = path.rsplit("/", 1)[-1].lower()
            if app not in PORTS:
                self._send_json(400, {"error": "unknown app"})
                return True

            def _switch() -> None:
                try:
                    subprocess.run(
                        [SWITCH_SCRIPT, app],
                        capture_output=True,
                        text=True,
                        timeout=600,
                        check=False,
                    )
                except Exception as exc:
                    print(f"[gateway] switch to {app} failed: {exc}", flush=True)

            threading.Thread(target=_switch, daemon=True, name=f"switch-{app}").start()
            self._send_html("switching.html")
            return True

        return False

    def _build_forward_headers(self, app: str, backend_path: str) -> dict[str, str]:
        headers: dict[str, str] = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in SKIP_REQUEST_HEADERS:
                continue
            headers[key] = value

        host = self.headers.get("Host", "")
        prefix = APP_PREFIXES.get(app, "")
        if host and prefix:
            headers["X-Forwarded-Host"] = host
            headers["X-Forwarded-Prefix"] = prefix
            headers["X-Hub-App"] = app
        headers["X-Forwarded-Proto"] = os.environ.get("FORWARDED_PROTO", "https")
        headers["X-Real-IP"] = self.client_address[0]
        prior = self.headers.get("X-Forwarded-For", "")
        client_ip = self.client_address[0]
        headers["X-Forwarded-For"] = f"{prior}, {client_ip}" if prior else client_ip
        # Never ask backends for br/gzip — we rewrite bodies as text and must not
        # forward compressed bytes after stripping Content-Encoding.
        headers["Accept-Encoding"] = "identity"
        return headers

    def _warming_response(self, app: str) -> None:
        accept = self.headers.get("Accept", "")
        if "text/html" in accept or self.path.endswith("/"):
            self._send_html("switching.html")
            return
        self._send_json(
            503,
            {
                "error": "backend_starting",
                "app": app,
                "retry_after_sec": 5,
                "hint": f"First open of {app} can take 1–3 minutes on HF free tier.",
            },
        )

    def _proxy_http(self, method: str) -> None:
        path, query, referer = self._parsed()
        origin = self.headers.get("Origin", "")
        cookie = self.headers.get("Cookie", "")
        app, backend_path = resolve_route(path, referer, query, origin, cookie)

        if query and "?" not in backend_path:
            backend_path = f"{backend_path}?{query}"

        if not ensure_backend(app):
            self._warming_response(app)
            return

        prefix = APP_PREFIXES.get(app, "")
        port = backend_port(app)
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3600)
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else None

        try:
            conn.request(method, backend_path, body=body, headers=self._build_forward_headers(app, backend_path))
            resp = conn.getresponse()
            data = resp.read()
            content_type = resp.getheader("Content-Type", "")
            content_encoding = resp.getheader("Content-Encoding")
            data, decompressed = decompress_body(data, content_encoding)
            if prefix:
                data = rewrite_app_body(data, content_type, prefix, app)

            self.send_response(resp.status)
            for key, value in resp.getheaders():
                lower = key.lower()
                if lower in HOP_BY_HOP or lower == "content-length":
                    continue
                if prefix and lower in SKIP_RESPONSE_CACHE_HEADERS:
                    continue
                if lower == "content-encoding":
                    # Drop encoding only when we successfully decoded; otherwise keep
                    # header + compressed bytes intact (avoids binary garbage in browser).
                    if decompressed:
                        continue
                    self.send_header(key, value)
                    continue
                if lower == "location" and prefix:
                    value = rewrite_location(value, prefix)
                self.send_header(key, value)
            if prefix:
                for key, value in proxy_cache_headers(app, content_type).items():
                    self.send_header(key, value)
            if app == "sillytavern" and (
                backend_path.endswith(".js") or "javascript" in content_type.lower()
            ):
                self.send_header("Cache-Control", "no-store, must-revalidate")
            if "text/html" in content_type.lower() and app in PORTS:
                self.send_header(
                    "Set-Cookie",
                    f"hub_app={app}; Path=/; SameSite=Lax; Max-Age=86400",
                )
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:
            print(f"[gateway] proxy {method} {app} → :{port}{backend_path} failed: {exc}", flush=True)
            self._send_json(502, {"error": "backend unavailable", "app": app, "port": port})
        finally:
            conn.close()

    def _proxy_websocket(self) -> None:
        path, query, referer = self._parsed()
        origin = self.headers.get("Origin", "")
        cookie = self.headers.get("Cookie", "")
        app, backend_path = resolve_route(path, referer, query, origin, cookie)
        if not ensure_backend(app):
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if query and "?" not in backend_path:
            backend_path = f"{backend_path}?{query}"

        port = backend_port(app)
        lines = [f"{self.command} {backend_path} {self.request_version}"]
        for key, value in self.headers.items():
            lower = key.lower()
            if lower == "host":
                value = f"127.0.0.1:{port}"
            lines.append(f"{key}: {value}")
        lines.extend(["", ""])
        payload = "\r\n".join(lines).encode("latin-1", errors="replace")

        client = self.connection
        backend = socket.create_connection(("127.0.0.1", port), timeout=60)
        try:
            backend.sendall(payload)
            sockets = [client, backend]
            while True:
                readable, _, _ = select.select(sockets, [], [], 3600)
                if not readable:
                    break
                for sock in readable:
                    chunk = sock.recv(65536)
                    if not chunk:
                        return
                    other = backend if sock is client else client
                    other.sendall(chunk)
        except Exception as exc:
            print(f"[gateway] websocket {app} → :{port}{backend_path} failed: {exc}", flush=True)
        finally:
            backend.close()

    def handle(self) -> None:
        try:
            self.raw_requestline = self.rfile.readline(65537)
            if not self.raw_requestline:
                return
            if not self.parse_request():
                return

            if self._handle_hub_route(self.command):
                return

            if self.headers.get("Upgrade", "").lower() == "websocket":
                self._proxy_websocket()
                return

            mname = f"do_{self.command}"
            if not hasattr(self, mname):
                self.send_error(501, "Unsupported method")
                return
            getattr(self, mname)()
        except (ConnectionResetError, BrokenPipeError):
            pass

    def do_GET(self) -> None:
        self._proxy_http("GET")

    def do_HEAD(self) -> None:
        self._proxy_http("HEAD")

    def do_POST(self) -> None:
        self._proxy_http("POST")

    def do_PUT(self) -> None:
        self._proxy_http("PUT")

    def do_PATCH(self) -> None:
        self._proxy_http("PATCH")

    def do_DELETE(self) -> None:
        self._proxy_http("DELETE")

    def do_OPTIONS(self) -> None:
        self._proxy_http("OPTIONS")


def main() -> None:
    print(
        f"[gateway] starting on 0.0.0.0:{HUB_PORT} mode=st-repo+v18-lazy "
        f"st_ref={os.environ.get('ST_REF', '1.18.0')} "
        f"prefixes={','.join(APP_PREFIXES.values())} hub=/hub",
        flush=True,
    )
    server = ThreadingHTTPServer(("0.0.0.0", HUB_PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()