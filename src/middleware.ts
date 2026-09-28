import { createServerClient } from "@supabase/ssr";
import createIntlMiddleware from "next-intl/middleware";
import type { NextRequest } from "next/server";

import { routing } from "./i18n/routing";

const handleIntl = createIntlMiddleware(routing);

/**
 * Two jobs in one pass: pick the locale, and keep the volunteer's Supabase session fresh.
 *
 * The order matters. next-intl produces the response (it may rewrite or redirect), and the
 * refreshed auth cookies are then written onto that same response. Creating a second response
 * would drop the rewrite and send everyone to the wrong locale.
 */
export async function middleware(request: NextRequest) {
  const response = handleIntl(request);

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (url && key) {
    const supabase = createServerClient(url, key, {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(list) {
          for (const { name, value, options } of list) {
            response.cookies.set(name, value, options);
          }
        },
      },
    });

    // Touching getUser() is what triggers the refresh-token rotation.
    await supabase.auth.getUser();
  }

  // Remember that the onboarding screen has been shown.
  //
  // Screens 1 and 2 of the design reference are a splash and an onboarding screen, and /welcome
  // is the second of those. It was built and deployed and then nothing ever linked to it, so the
  // first thing a new visitor actually saw was the marketing landing page, which is not in the
  // reference at all. The home page now sends a first-time signed-out visitor here; this is what
  // stops it happening on every subsequent visit.
  //
  // Set in the middleware rather than from the page, because a server component cannot set a
  // cookie and a client effect would leave anybody with JavaScript off pinned to onboarding
  // forever. Written on the response that actually carries /welcome, so it lands whether the
  // visitor arrived by redirect or typed the URL.
  if (/^\/(en\/|es\/)?welcome\/?$/.test(request.nextUrl.pathname)) {
    response.cookies.set(SEEN_WELCOME, "1", {
      path: "/",
      maxAge: 60 * 60 * 24 * 365,
      sameSite: "lax",
      httpOnly: false,
    });
  }

  return response;
}

/** Cookie recording that onboarding has been seen. Read by the home page. */
export const SEEN_WELCOME = "wu_seen_welcome";

export const config = {
  // Everything except API routes, the generated icons, Next internals, and files with an
  // extension.
  //
  // `auth` has to be here: /auth/callback lives outside `[locale]`, because the redirect URL is
  // registered once in the Supabase dashboard and cannot vary per language. Without the
  // exclusion the locale rewrite sends it into the locale tree where no route exists, and every
  // emailed confirmation and password-reset link 404s on arrival. Files with an extension — the
  // manifest, robots.txt, sitemap.xml, offline.html, /brand/*.png — are covered by the
  // extension rule already.
  //
  // `monitoring` is the Sentry tunnel (tunnelRoute in next.config.ts). It is a rewrite to
  // Sentry's ingest rather than a route in the app, so sending it through the locale middleware
  // would look for /en/monitoring and find nothing. It resolves before this middleware today and
  // works without the exclusion — which is exactly why it is written down here. The failure mode
  // if that ordering ever changes is silence: events stop arriving, nothing throws, and an app
  // with broken error tracking is indistinguishable from an app with no errors. Verified in
  // production by posting to /monitoring with the o/p/r query params the SDK sends and getting
  // 401 from Sentry's ingest rather than 404 from Next.
  //
  // The backslash must be doubled: this is a JS string, so "\\." is what the regex engine
  // receives as `\.`. Written as "\." it collapses to ".", the pattern becomes `.*..*`, and the
  // matcher then excludes every path of two or more characters — which silently 404s every
  // unprefixed URL in the app while the bare "/" keeps working.
  matcher: ["/((?!api|auth|monitoring|_next|_vercel|.*\\..*).*)"],
};
