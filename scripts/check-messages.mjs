#!/usr/bin/env node
/**
 * Fails if messages/en.json and messages/es.json have drifted apart.
 *
 * "Every user-facing string exists in EN and ES" only holds if something checks. A missing
 * Spanish key does not throw at runtime — next-intl falls back and the screen quietly goes
 * English, which is exactly the failure this project is meant not to have.
 *
 * Run with: npm run i18n:check
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const messagesDir = join(here, "..", "messages");

function load(locale) {
  return JSON.parse(readFileSync(join(messagesDir, `${locale}.json`), "utf8"));
}

function flatten(value, prefix = "", out = new Map()) {
  for (const [key, child] of Object.entries(value)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (child && typeof child === "object" && !Array.isArray(child)) {
      flatten(child, path, out);
    } else {
      out.set(path, child);
    }
  }
  return out;
}

/**
 * ICU placeholders, so a translation cannot silently drop {count} or {url}.
 *
 * This needs a real brace walk rather than a regex. In
 * `{count, plural, =0 {Open} other {Open (#)}}` the branch body `{Open}` is indistinguishable
 * from a placeholder by shape alone, and a regex flags it — which then reports every correctly
 * translated plural as a mismatch, because the English branch says "Open" and the Spanish one
 * says "Abiertas".
 *
 * So: read each argument, take its name, and for plural/select recurse into the branch bodies as
 * message text. A nested `{miles}` inside a branch is still a real placeholder and is collected.
 */
function matchingBrace(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i += 1) {
    if (text[i] === "{") depth += 1;
    else if (text[i] === "}") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function collectPlaceholders(text, found) {
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] !== "{") continue;

    const close = matchingBrace(text, i);
    if (close === -1) break;

    const inner = text.slice(i + 1, close);
    const comma = inner.indexOf(",");
    const name = (comma === -1 ? inner : inner.slice(0, comma)).trim();

    if (/^\w+$/.test(name)) found.add(name);

    if (comma !== -1) {
      const rest = inner.slice(comma + 1);
      const type = (rest.split(",")[0] ?? "").trim();

      if (type === "plural" || type === "select" || type === "selectordinal") {
        const styleStart = rest.indexOf(",");
        const style = styleStart === -1 ? "" : rest.slice(styleStart + 1);

        for (let j = 0; j < style.length; j += 1) {
          if (style[j] !== "{") continue;
          const branchEnd = matchingBrace(style, j);
          if (branchEnd === -1) break;
          collectPlaceholders(style.slice(j + 1, branchEnd), found);
          j = branchEnd;
        }
      }
    }

    i = close;
  }

  return found;
}

function placeholders(text) {
  if (typeof text !== "string") return new Set();
  return collectPlaceholders(text, new Set());
}

const en = flatten(load("en"));
const es = flatten(load("es"));

const problems = [];

for (const key of en.keys()) {
  if (!es.has(key)) problems.push(`missing in es: ${key}`);
}

for (const key of es.keys()) {
  if (!en.has(key)) problems.push(`missing in en: ${key}`);
}

for (const key of en.keys()) {
  if (!es.has(key)) continue;

  const expected = placeholders(en.get(key));
  const actual = placeholders(es.get(key));

  for (const name of expected) {
    if (!actual.has(name)) problems.push(`es.${key} is missing the {${name}} placeholder`);
  }
  for (const name of actual) {
    if (!expected.has(name)) problems.push(`es.${key} has an extra {${name}} placeholder`);
  }

  if (typeof es.get(key) === "string" && es.get(key).trim() === "") {
    problems.push(`es.${key} is empty`);
  }
}

if (problems.length > 0) {
  console.error(`i18n check failed (${problems.length} problem(s)):\n`);
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log(`i18n check passed: ${en.size} keys, en and es in step.`);
