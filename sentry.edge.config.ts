import * as Sentry from "@sentry/nextjs";

import { SENTRY_DSN, sentryOptions } from "@/lib/observability/sentry-options";

// The middleware runs here. Same options, same refusals.
if (SENTRY_DSN) {
  Sentry.init(sentryOptions);
}
