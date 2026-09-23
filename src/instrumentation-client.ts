import type * as SentryTypes from "@sentry/nextjs";

import { SENTRY_DSN, sentryOptions } from "@/lib/observability/sentry-options";

/**
 * The browser half, loaded only if it is actually going to be used.
 *
 * The SDK is imported dynamically rather than at the top of the file, and that is not a style
 * choice. A static import puts it in the chunk every page shares whether or not a DSN is set:
 * measured at +61 kB, from 103 kB to 164 kB, paid by every visitor on every page. The page that
 * cost lands on hardest is the request wizard, opened by somebody sitting in a field on one bar
 * of signal — which is the exact person this product exists for.
 *
 * Dynamic, the bundler splits it out. No DSN, and it is never fetched at all. With a DSN it is
 * fetched after the page is interactive, so error tracking never competes with the wizard for
 * the first two seconds of a bad connection.
 *
 * The trade: an error thrown in the first moments of page load, before this resolves, is missed
 * in the browser. Server-rendered failures are caught regardless, and those are most of the ones
 * that matter here.
 */

let sentry: typeof SentryTypes | null = null;

if (SENTRY_DSN) {
  void import("@sentry/nextjs").then((module) => {
    sentry = module;
    module.init(sentryOptions);
  });
}

/**
 * Navigation errors after hydration. A no-op until the SDK has loaded, and a no-op for ever when
 * there is no DSN.
 */
export function onRouterTransitionStart(
  ...args: Parameters<typeof SentryTypes.captureRouterTransitionStart>
) {
  sentry?.captureRouterTransitionStart(...args);
}
