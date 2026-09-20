import type { MetadataRoute } from "next";

/** Only the pages that should be found. Nothing token-scoped appears here. */
export default function sitemap(): MetadataRoute.Sitemap {
  const site = (process.env.NEXT_PUBLIC_SITE_URL ?? "http://127.0.0.1:3000").replace(/\/$/, "");
  const now = new Date();

  const paths = ["", "/board", "/join", "/request", "/terms", "/waiver", "/privacy"];

  return paths.flatMap((path) => [
    { url: `${site}${path || "/"}`, lastModified: now, changeFrequency: "daily" as const },
    { url: `${site}/es${path}`, lastModified: now, changeFrequency: "daily" as const },
  ]);
}
