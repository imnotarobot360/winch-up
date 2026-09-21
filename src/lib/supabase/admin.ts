import "server-only";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

/**
 * Service-role client. Bypasses RLS.
 *
 * Only ever imported from server actions and route handlers. The `server-only` import above turns
 * an accidental client import into a build error rather than a leaked key.
 */
let cached: SupabaseClient | null = null;

export function supabaseAdmin(): SupabaseClient {
  if (cached) return cached;

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    throw new Error(
      "Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY. Copy .env.example to .env.local and fill them in.",
    );
  }

  cached = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { "x-winchup-client": "server" } },
  });

  return cached;
}

export const PHOTO_BUCKET = "request-photos";

/**
 * The client's IP, as far as we can tell behind Vercel's proxy.
 *
 * Used for rate limiting and stored with the waiver acceptance. It is spoofable by anyone who
 * talks to the origin directly, which is why it is never the only limit — the per-phone limit
 * sits behind it.
 */
export function clientIpFrom(headers: Headers): string | null {
  const forwarded = headers.get("x-forwarded-for");
  if (forwarded) {
    const first = forwarded.split(",")[0]?.trim();
    if (first) return first;
  }
  return headers.get("x-real-ip") ?? null;
}
