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

  return NextResponse.redirect(new URL(safeNext, url.origin));
}
