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

  return response;
}

export const config = {
  // Everything except API routes, Next internals and files with an extension.
  matcher: ["/((?!api|_next|_vercel|.*\..*).*)"],
};
