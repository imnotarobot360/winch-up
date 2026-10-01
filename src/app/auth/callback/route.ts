import { cookies } from "next/headers";
import { NextResponse } from "next/server";

import { RETURN_COOKIE, safeReturnPath } from "@/lib/auth/return-path";
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

  /**
   * Where to go afterwards, in order: an explicit ?next, then the cookie, then /me.
   *
   * THE COOKIE EXISTS BECAUSE ?next CANNOT BE USED FOR OAUTH. Supabase matches redirect_to
   * against an exact allowlist, and the bare callback carrying a query string does not match
   * it -- Supabase then falls back to the Site URL without saying so, which looks like the app
   * sending people to the wrong page. A cookie survives the round trip: the return from the
   * provider is a top-level GET, which carries SameSite=Lax cookies.
   *
   * Both go through the same validator. The cookie is written by client JavaScript and is
   * exactly as trustworthy as the query parameter, which is to say not at all, and either one
   * ends up in a redirect from this domain.
   */
  const jar = await cookies();
  const destination =
    safeReturnPath(url.searchParams.get("next")) ??
    safeReturnPath(jar.get(RETURN_COOKIE)?.value) ??
    "/me";

  /** Clear the cookie on every path out of here, including the failures. */
  const leave = (to: string) => {
    const res = NextResponse.redirect(new URL(to, url.origin));
    res.cookies.delete(RETURN_COOKIE);
    return res;
  };

  if (!code) {
    return leave("/signin?error=missing_code");
  }

  const supabase = await supabaseServer();
  const { error } = await supabase.auth.exchangeCodeForSession(code);

  if (error) {
    console.error("[auth/callback] exchange failed", error.message);
    return leave("/signin?error=link_expired");
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
      // The agreement wins over the saved destination -- it is the one thing that must not
      // be skipped -- and the cookie is dropped rather than held, so signing it later cannot
      // bounce somebody somewhere they have forgotten asking for.
      return leave("/agreement");
    }
  } catch (cause) {
    console.error("[auth/callback] membership check failed, continuing", cause);
  }

  return leave(destination);
}
