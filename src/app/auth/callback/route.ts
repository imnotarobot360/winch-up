import { NextResponse } from "next/server";

import { supabaseServer } from "@/lib/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Where an emailed confirmation link lands.
 *
 * Supabase's PKCE flow sends a `code` that has to be exchanged for a session on the server, so
 * the session cookie is set by us rather than by client JavaScript. This route lives outside
 * [locale] because the redirect URL is registered in the Supabase dashboard and has to be one
 * fixed string, not one per language.
 *
 * `next` is validated before use: an open redirect here would let a phishing link borrow our
 * domain and our TLS certificate to bounce someone somewhere else.
 */
export async function GET(request: Request) {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const next = url.searchParams.get("next") ?? "/me";

  // Relative paths only, and no protocol-relative "//evil.com" either.
  const safeNext = next.startsWith("/") && !next.startsWith("//") ? next : "/me";

  if (!code) {
    return NextResponse.redirect(new URL("/signin?error=missing_code", url.origin));
  }

  const supabase = await supabaseServer();
  const { error } = await supabase.auth.exchangeCodeForSession(code);

  if (error) {
    console.error("[auth/callback] exchange failed", error.message);
    return NextResponse.redirect(new URL("/signin?error=link_expired", url.origin));
  }

  /**
   * Requirement 2: the membership agreement is part of registration, not something bolted on
   * afterwards. This is the seam -- the member has just proved they own the address, and the
   * very next screen is the thing they have to sign.
   *
   * Placed here rather than as a step inside the signup form because the form finishes BEFORE
   * the address is verified. A signature collected there would be a legal record attached to
   * an account that might never be confirmed, signed by somebody who had not yet demonstrated
   * they are reachable.
   *
   * NEVER BLOCKS SIGN-IN. `needs_signature` is false whenever no agreement is published, which
   * is how this ships, and any failure reading it falls through to the normal destination. An
   * account that cannot get past its own confirmation link is worse than an unsigned one, and
   * this route is the single point where that could happen to everybody at once.
   */
  try {
    const { data } = await supabase.rpc("membership_agreement");
    const state = (data as { state?: { needs_signature?: boolean } } | null)?.state;

    if (state?.needs_signature) {
      return NextResponse.redirect(new URL("/agreement", url.origin));
    }
  } catch (cause) {
    console.error("[auth/callback] membership check failed, continuing", cause);
  }

  return NextResponse.redirect(new URL(safeNext, url.origin));
}
