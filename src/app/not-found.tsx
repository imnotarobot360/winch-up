/**
 * Global 404.
 *
 * Almost every request goes through the middleware and lands under `[locale]`, which renders
 * `[locale]/not-found.tsx` inside a proper document. This one catches what the middleware skips
 * — paths with a file extension, mainly — and has to render its own <html> and <body>, because
 * the root layout deliberately renders neither.
 *
 * No translations here: there is no locale to read at this point in the tree.
 */
export default function GlobalNotFound() {
  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          padding: "48px 16px",
          font: '18px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
          color: "#0b0f14",
          background: "#fff",
          textAlign: "center",
        }}
      >
        <main style={{ maxWidth: "32rem", margin: "0 auto" }}>
          <h1 style={{ fontSize: "1.75rem", margin: "0 0 8px" }}>Page not found</h1>
          <p style={{ color: "#3d4754" }}>Página no encontrada</p>
          <p style={{ marginTop: 24 }}>
            <a href="/" style={{ color: "#e2560f", fontWeight: 700 }}>
              Go to TxRecover
            </a>
          </p>
        </main>
      </body>
    </html>
  );
}
