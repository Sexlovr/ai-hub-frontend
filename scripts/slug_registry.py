"""Canonical character slug registry for hub sync v2."""
from __future__ import annotations

import re

# Merge legacy slug variants into one canonical identity.
SLUG_ALIASES: dict[str, str] = {
    "default_seraphina": "seraphina",
    "default_seraphina_png": "seraphina",
}

GLOBAL_CANONICAL_RE = re.compile(r"^hub_[a-z][a-z0-9_]+\.png$", re.I)
HUB_SOURCE_PREFIX_RE = re.compile(r"^hub_(st|marinara|lumiverse)_", re.I)
ST_RANDOM_ID_SLUG_RE = re.compile(r"^([a-z0-9]{6,12})_")


def normalize_slug(slug: str) -> str:
    slug = slug.strip().lower()
    return SLUG_ALIASES.get(slug, slug)


def name_slug(name: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\u0000-\u001f]+', " ", name or "")
    cleaned = re.sub(r"\s+", " ", cleaned).strip().lower()
    slug = re.sub(r"[^a-z0-9]+", "_", cleaned).strip("_")
    return normalize_slug(slug[:60] or "character")


def canonical_filename(name: str) -> str:
    return f"hub_{name_slug(name)}.png"


def is_global_canonical(name: str) -> bool:
    return bool(GLOBAL_CANONICAL_RE.match(name)) and not HUB_SOURCE_PREFIX_RE.match(name)


def is_random_st_id_slug(slug: str) -> bool:
    m = ST_RANDOM_ID_SLUG_RE.match(slug)
    if not m:
        return False
    return any(ch.isdigit() for ch in m.group(1))