"use client";

import { createBrowserClient } from "@supabase/ssr";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

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

/**
 * A throwaway client that CANNOT touch the signed-in session.
 *
 * For one job: checking that somebody knows their current password, on /account/security, by
 * signing in with it. Doing that on the normal client would work and would also be a bug --
 * signInWithPassword REPLACES the stored session, and a session that has been through MFA is at
 * aal2 while a fresh password sign-in is at aal1. An admin changing their password would
 * silently lose admin access until they re-verified, with nothing on screen to explain it.
 *
 * `persistSession: false` keeps the resulting session in memory, and a distinct `storageKey`
 * means even a future change of that flag cannot make it overwrite the real one. Not cached:
 * it exists for the length of one check and is then garbage.
 */
export function supabaseThrowaway(): SupabaseClient {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !key) {
    throw new Error(
      "Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY. Copy .env.example to .env.local.",
    );
  }

  return createClient(url, key, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
      storageKey: "winchup-password-check",
    },
  });
}
