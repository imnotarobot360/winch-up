"use client";

import { useEffect } from "react";

/**
 * The last resort: a React rendering error that escaped every other boundary.
 *
 * This replaces the entire document, so it carries its own `<html>` and `<body>` and cannot use
 * anything from the layout — no fonts, no Tailwind, no translations. Which is the same
 * constraint `public/offline.html` works under, and the same answer: inline styles, both
 * languages on screen at once because there is nobody left to ask which one to use, and one
 * thing to do next.
 *
 * The one thing to do next is not "reload". If somebody is looking at this screen while their
 * truck is in a creek, reloading a broken page is not the advice they need.
 */
export default function GlobalError({ error }: { error: Error & { digest?: string } }) {
  useEffect(() => {
    // Imported here rather than at the top of the file so this page carries no cost for the
    // visitors who never see it -- which, if everything else is working, is all of them.
    if (process.env.NEXT_PUBLIC_SENTRY_DSN) {
      void import("@sentry/nextjs").then((Sentry) => Sentry.captureException(error));
    }
  }, [error]);

  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          padding: "48px 16px",
          font: '18px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
          color: "#f2f5f3",
          background: "#08150f",
          textAlign: "center",
        }}
      >
        <main style={{ maxWidth: "32rem", margin: "0 auto" }}>
          <h1 style={{ fontSize: "1.75rem", margin: "0 0 8px" }}>Something broke</h1>
          <p style={{ color: "#b6c6bd", margin: "0 0 24px" }}>Algo se rompió</p>

          <p style={{ margin: "0 0 8px" }}>
            If anyone is hurt, in water, or in traffic, call 911. We are volunteers, not emergency
            services.
          </p>
          <p style={{ color: "#b6c6bd", margin: "0 0 32px" }}>
            Si hay alguien lastimado, en el agua o en el tráfico, llama al 911. Somos voluntarios,
            no servicios de emergencia.
          </p>

          <p style={{ margin: 0 }}>
            {/* A plain anchor, not next/link, and the rule is disabled on purpose. Link does a
                client-side navigation through the router — the same router inside the React tree
                that has just crashed. A full page load is the only thing that reliably gets
                somebody off this screen. */}
            {/* eslint-disable-next-line @next/next/no-html-link-for-pages */}
            <a href="/" style={{ color: "#ff9147", fontWeight: 700 }}>
              Start again · Empezar de nuevo
            </a>
          </p>

          {/* The digest is what ties this screen to the report. No stack, no message: whatever
              threw could have had somebody's data in it. */}
          {error.digest ? (
            <p style={{ color: "#6f8579", fontSize: "0.8rem", marginTop: 32 }}>
              Reference: {error.digest}
            </p>
          ) : null}
        </main>
      </body>
    </html>
  );
}
