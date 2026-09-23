import * as Sentry from "@sentry/nextjs";

import { SENTRY_DSN, sentryOptions } from "@/lib/observability/sentry-options";

// No DSN, no SDK. The app runs exactly as it did before error tracking existed -- which is the
// state it is in until somebody sets the variable, and the state every local build is in.
if (SENTRY_DSN) {
  Sentry.init(sentryOptions);
}
