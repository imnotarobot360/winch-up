import * as Sentry from "@sentry/nextjs";

/**
 * Next calls this once per runtime, before anything else.
 *
 * Two runtimes, two configs, because the edge runtime has no Node APIs and the SDK builds
 * differently for each.
 */
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    await import("../sentry.server.config");
  }

  if (process.env.NEXT_RUNTIME === "edge") {
    await import("../sentry.edge.config");
  }
}

/**
 * Errors thrown while rendering a server component or handling a request. Without this they are
 * logged by Vercel and nowhere else, which is the half of the app where the errors that matter
 * live -- a recovery that did not dispatch, a text that did not send.
 */
export const onRequestError = Sentry.captureRequestError;
