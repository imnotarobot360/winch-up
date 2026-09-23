import { withSentryConfig } from "@sentry/nextjs/config";
import createNextIntlPlugin from "next-intl/plugin";
import type { NextConfig } from "next";

const withNextIntl = createNextIntlPlugin("./src/i18n/request.ts");

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  // Photos are served through short-lived signed URLs from a private bucket, so there is no
  // remote image host to allowlist. Keep it that way.
  images: { remotePatterns: [] },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "X-Frame-Options", value: "DENY" },
        ],
      },
      {
        // A status link gets forwarded around by the people helping. It must never be indexed.
        source: "/:locale/r/:token*",
        headers: [{ key: "X-Robots-Tag", value: "noindex, nofollow" }],
      },
      {
        source: "/r/:token*",
        headers: [{ key: "X-Robots-Tag", value: "noindex, nofollow" }],
      },
    ];
  },
};

/**
 * Sentry wraps the build to upload source maps, so a stack trace names a line of TypeScript
 * rather than a column in a minified chunk.
 *
 * Every part of it is conditional on credentials that are absent locally and in CI. Without
 * SENTRY_AUTH_TOKEN nothing is uploaded and the build is unchanged; without NEXT_PUBLIC_SENTRY_DSN
 * the SDK never initialises at runtime either. Verified by building with no environment at all.
 *
 * `deleteSourcemapsAfterUpload` matters: the maps go to Sentry and are then removed from the
 * build output, so a stack trace is readable to whoever is fixing it and not to whoever is
 * reading the page. (This replaces `hideSourceMaps`, which the SDK dropped in v10 — the
 * typechecker caught that rather than it shipping as a silently ignored option.)
 */
export default withSentryConfig(withNextIntl(nextConfig), {
  org: process.env.SENTRY_ORG,
  project: process.env.SENTRY_PROJECT,
  authToken: process.env.SENTRY_AUTH_TOKEN,

  silent: !process.env.CI,
  widenClientFileUpload: true,
  sourcemaps: { deleteSourcemapsAfterUpload: true },
  webpack: { treeshake: { removeDebugLogging: true } },

  // Routes Sentry's own requests through this domain so an ad blocker does not silently swallow
  // every error report. Costs one rewrite and is the difference between error tracking and the
  // appearance of error tracking.
  tunnelRoute: "/monitoring",
});
