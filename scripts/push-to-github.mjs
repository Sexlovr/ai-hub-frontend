#!/usr/bin/env node
/**
 * One-shot GitHub push via Contents API (no git required).
 * Usage: GITHUB_TOKEN=... GITHUB_USER=Sexlovr node scripts/push-to-github.mjs
 */
import { readFileSync, readdirSync, statSync } from "fs";
import { join, relative } from "path";
import { fileURLToPath } from "url";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const USER = process.env.GITHUB_USER || "Sexlovr";
const TOKEN = process.env.GITHUB_TOKEN;
const REPO = process.env.GITHUB_REPO || "ai-hub-frontend";

if (!TOKEN) {
  console.error("GITHUB_TOKEN is required");
  process.exit(1);
}

const API = "https://api.github.com";
const headers = {
  Authorization: `Bearer ${TOKEN}`,
  Accept: "application/vnd.github+json",
  "User-Agent": "ai-frontends-hub-push",
  "X-GitHub-Api-Version": "2022-11-28",
};

async function gh(path, opts = {}) {
  const res = await fetch(`${API}${path}`, { ...opts, headers: { ...headers, ...opts.headers } });
  const text = await res.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  if (!res.ok) {
    throw new Error(`${opts.method || "GET"} ${path} -> ${res.status}: ${JSON.stringify(body)}`);
  }
  return body;
}

function walk(dir, acc = []) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    const rel = relative(ROOT, full);
    if (rel.startsWith(".git")) continue;
    const st = statSync(full);
    if (st.isDirectory()) walk(full, acc);
    else acc.push(rel);
  }
  return acc;
}

async function main() {
  let repoExists = true;
  try {
    await gh(`/repos/${USER}/${REPO}`);
  } catch {
    repoExists = false;
  }

  if (!repoExists) {
    console.error(`Repository ${USER}/${REPO} does not exist.`);
    console.error(`Create it first: https://github.com/new?name=${REPO}&description=AI+frontends+hub`);
    console.error("Fine-grained tokens need this repo added under token Repository access + Contents: Read and write.");
    process.exit(1);
  }

  const files = walk(ROOT).filter(
    (f) =>
      (!f.startsWith("data/") || f.includes("shared")) &&
      !f.includes("__pycache__") &&
      !f.endsWith(".pyc"),
  );
  console.log(`Uploading ${files.length} files...`);

  for (const file of files.sort()) {
    const content = readFileSync(join(ROOT, file));
    const encoding = "base64";
    const payload = {
      message: `Add ${file}`,
      content: content.toString("base64"),
    };

    let existing = null;
    try {
      existing = await gh(`/repos/${USER}/${REPO}/contents/${encodeURIComponent(file).replace(/%2F/g, "/")}`);
    } catch {
      /* new file */
    }
    if (existing?.sha) payload.sha = existing.sha;

    await gh(`/repos/${USER}/${REPO}/contents/${file.split("/").map(encodeURIComponent).join("/")}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    console.log(`  ✓ ${file}`);
  }

  console.log(`\nDone: https://github.com/${USER}/${REPO}`);
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});