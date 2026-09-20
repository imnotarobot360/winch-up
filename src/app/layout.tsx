import type { ReactNode } from "react";

/**
 * Intentionally bare.
 *
 * Every real route lives under `[locale]`, and that layout renders <html> and <body>. This file
 * exists only because Next.js requires a root layout; adding markup here would produce two
 * <html> elements.
 */
export default function RootLayout({ children }: { children: ReactNode }) {
  return children;
}
