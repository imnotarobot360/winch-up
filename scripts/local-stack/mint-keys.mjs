#!/usr/bin/env node
/**
 * Mint the anon and service_role JWTs the local stack uses.
 *
 * Same shape Supabase issues: HS256, signed with the project's JWT secret, carrying a `role`
 * claim that PostgREST turns into a SET ROLE. Writes keys.json next to this script.
 */
import crypto from "node:crypto";
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const secret =
  process.env.LOCAL_JWT_SECRET ?? "txrecover-local-dev-jwt-secret-at-least-32-chars";

const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

function sign(role) {
  const now = Math.floor(Date.now() / 1000);
  const payload = `${b64({ alg: "HS256", typ: "JWT" })}.${b64({
    role,
    iss: "supabase",
    iat: now,
    exp: now + 60 * 60 * 24 * 365,
  })}`;
  return `${payload}.${crypto.createHmac("sha256", secret).update(payload).digest("base64url")}`;
}

const keys = { secret, anon: sign("anon"), service: sign("service_role") };
const out = join(dirname(fileURLToPath(import.meta.url)), "keys.json");
writeFileSync(out, JSON.stringify(keys, null, 2) + "\n");

console.log(`wrote ${out}`);
console.log(`NEXT_PUBLIC_SUPABASE_ANON_KEY=${keys.anon}`);
console.log(`SUPABASE_SERVICE_ROLE_KEY=${keys.service}`);
