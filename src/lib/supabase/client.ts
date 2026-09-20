"use client";

import { createBrowserClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * Browser client, carrying the signed-in volunteer's session.
 *
 * Volunteer actions (accept, decline, on site, done, pause) go through this rather than a server
 * action, because every one of them is a `security definer` RPC that resolves the caller from
 * `auth.uid()`. Sending them through the server would mean forwarding the JWT for no benefit.
 */
let cached: SupabaseClient | null = null;

export function supabaseBrowser(): SupabaseClient {
  if (cached) return cached;

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !key) {
    throw new Error(
      "Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY. Copy .env.example to .env.local.",
    );
  }

  cached = createBrowserClient(url, key);
  return cached;
}
