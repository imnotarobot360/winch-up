import type { ErrorEvent } from "@sentry/nextjs";

import { scrubDeep, scrubUrl } from "./scrub";

/**
 * One set of options, shared by the browser, the server and the edge runtime.
 *
 * Shared rather than repeated because the three configs would otherwise drift, and the setting
 * that drifts is always the one that matters. `sendDefaultPii` being true in one of three places
 * is not a smaller mistake than being true in all three.
 *
 * WHAT IS DELIBERATELY OFF
 *
 *   Session replay. It records what a person did on the screen. On this app that is a video of
 *   somebody's worst evening, including the pin they dropped on their own location. Not a
 *   setting so much as a refusal.
 *
 *   Performance tracing. Every trace carries URLs and timings for every request, which is a
 *   large amount of data about a small number of people, in exchange for knowing that a page
 *   took 800ms. Turn it on if there is ever a performance question worth that trade.
 *
 *   sendDefaultPii. Off, which means no IP address and no request body.
 *
 * Together these also keep the browser bundle small, which is not a side benefit here: this app
 * is read on a three-year-old Android on one bar of signal, and the replay and tracing
 * integrations are most of the SDK's weight.
 */
export const SENTRY_DSN = process.env.NEXT_PUBLIC_SENTRY_DSN ?? "";

/**
 * Errors that are somebody else's, or nobody's. Each one here was chosen because it would
 * otherwise drown the real ones.
 */
const IGNORE = [
  // A person navigating away mid-request. Not a fault.
  "AbortError",
  "The operation was aborted",
  "NetworkError when attempting to fetch resource",
  "Failed to fetch",
  "Load failed",
  // Browser extensions and injected scripts.
  "ResizeObserver loop",
  "Non-Error promise rejection captured",
];

export const sentryOptions = {
  dsn: SENTRY_DSN,

  // Never. See above.
  sendDefaultPii: false,
  tracesSampleRate: 0,

  // So an error from a preview deployment is not mistaken for one that reached somebody.
  environment: process.env.VERCEL_ENV ?? process.env.NODE_ENV ?? "development",

  ignoreErrors: IGNORE,

  /**
   * The last thing that runs before an event leaves the process.
   *
   * Everything goes through the scrubber, including the parts Sentry assembled itself — stack
   * frames, breadcrumbs, request metadata, whatever somebody attached to `extra`. A denylist is
   * never perfect, so it is aggressive: a redacted order number costs nothing, a leaked phone
   * number costs somebody.
   */
  beforeSend(event: ErrorEvent): ErrorEvent | null {
    if (!SENTRY_DSN) return null;

    const scrubbed = scrubDeep(event);

    // The URL gets its own pass: `/r/<token>` is the key to a live recovery, and a generic text
    // scrub would leave it intact because it contains nothing that looks like a number.
    if (scrubbed.request?.url) {
      scrubbed.request.url = scrubUrl(scrubbed.request.url);
    }

    // Never send these, whatever is in them.
    if (scrubbed.request) {
      delete scrubbed.request.cookies;
      delete scrubbed.request.data;
      delete scrubbed.request.headers;
    }

    delete scrubbed.user;

    return scrubbed;
  },

  /**
   * Breadcrumbs are the trail of what happened before the error, and they are where a URL or a
   * form value is most likely to be sitting.
   */
  beforeBreadcrumb(breadcrumb: { data?: Record<string, unknown>; message?: string }) {
    if (!SENTRY_DSN) return null;
    return scrubDeep(breadcrumb);
  },
};
