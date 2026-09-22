#!/usr/bin/env node
/**
 * Fails if user-facing copy starts claiming things this app does not do.
 *
 * Phase 14: "Do not claim the app provides emergency rescue, guaranteed assistance, or
 * continuous location monitoring unless those capabilities are actually implemented and
 * supported." None of the three is implemented, and none should be claimed:
 *
 *   It is not an emergency service. Nobody is on shift. Volunteers choose whether to come.
 *   Nothing is guaranteed. A request can reach `unmatched` with nobody available, and does.
 *   Nothing is tracked. One position is stored when somebody presses a button, and it expires.
 *
 * A sentence promising otherwise would not be a marketing problem. It would be somebody
 * deciding not to call 911 because an app told them help was on the way.
 *
 * This is a word check, so it cannot tell "we are not an emergency service" from the opposite.
 * Every match has to be either fixed or listed in REVIEWED below with a note saying why it is
 * fine. Adding to that list is the point at which somebody has to think about it.
 *
 * Run with: npm run claims:check  (and as part of prebuild)
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const messagesDir = join(here, "..", "messages");

const PATTERNS = [
  [/\bemergency (service|rescue|response|assistance)\b/i, "claims to be an emergency service"],
  [/\b(rescue|recovery) guarantee|guarantee\w*\b/i, "guarantees something"],
  [/\b24\/7\b|\bround the clock\b|\bday or night we\b/i, "claims constant availability"],
  [/\bwe will always\b|\bsiempre vamos\b|\bsiempre llega\b/i, "promises we always turn up"],
  [/\bwe track\b|\btracking your\b|\btrack your location\b/i, "claims to track people"],
  [/\bmonitor(s|ing) (your|their) location\b|\bcontinuous location\b/i, "claims live monitoring"],
  [/\blive location\b|\breal[- ]time location\b|\bubicación en vivo\b/i, "claims live location"],
  [/\bservicio de emergencia\b/i, "claims to be an emergency service (es)"],
  [/\bgarantiza\w*\b|\bgarantía\b/i, "guarantees something (es)"],
  [/\brastrea\w*\b|\bseguimiento de (tu|su) ubicación\b/i, "claims to track people (es)"],
];

/**
 * Strings a human has read and cleared, with the reason. A match here is not an exception to
 * the rule -- it is a string that says the opposite of what the pattern looks for, or uses the
 * word in a way that promises nothing.
 */
const REVIEWED = new Map([
  [
    "resources.guides.stuck.sections.0.items.4",
    "says we are NOT an emergency service, which is the sentence the rule exists to encourage",
  ],
  [
    "me.location.note",
    "says nothing tracks you and the position expires -- a denial, not a claim",
  ],
  [
    "join.errors.no_verified_phone",
    "'lost track of your confirmed number' is the idiom, not location tracking",
  ],
  [
    "me.location.body",
    "explains that one position is stored on a button press and is not continuous",
  ],
]);

function flatten(value, prefix = "", out = []) {
  const entries = Array.isArray(value)
    ? value.map((child, index) => [String(index), child])
    : Object.entries(value);

  for (const [key, child] of entries) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (child && typeof child === "object") flatten(child, path, out);
    else out.push([path, String(child)]);
  }
  return out;
}

const problems = [];
let checked = 0;

for (const locale of ["en", "es"]) {
  const messages = JSON.parse(readFileSync(join(messagesDir, `${locale}.json`), "utf8"));

  for (const [key, text] of flatten(messages)) {
    checked += 1;
    if (REVIEWED.has(key)) continue;

    for (const [pattern, why] of PATTERNS) {
      if (pattern.test(text)) {
        problems.push(`${locale}.${key} ${why}\n      "${text.slice(0, 140)}"`);
      }
    }
  }
}

if (problems.length > 0) {
  console.error(`claims check failed (${problems.length} problem(s)):\n`);
  for (const problem of problems) console.error(`  - ${problem}\n`);
  console.error(
    "Either change the wording, or add the key to REVIEWED in scripts/check-claims.mjs with a\n" +
      "note saying why it is fine. Do not add it without reading it.",
  );
  process.exit(1);
}

console.log(`claims check passed: ${checked} strings, nothing overclaimed.`);
