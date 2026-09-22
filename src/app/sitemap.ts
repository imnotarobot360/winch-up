import type { MetadataRoute } from "next";

import { GUIDES } from "@/lib/resources";

/** Only the pages that should be found. Nothing token-scoped appears here. */
export default function sitemap(): MetadataRoute.Sitemap {
  const site = (process.env.NEXT_PUBLIC_SITE_URL ?? "http://127.0.0.1:3000").replace(/\/$/, "");
  const now = new Date();

  const paths = [
    "",
    "/board",
    "/join",
    "/request",
    "/terms",
    "/waiver",
    "/privacy",
    // The resources section is public on purpose: it is the one part of this app that is useful
    // to somebody who has never heard of us and is standing next to a stuck truck right now.
    "/resources",
    ...GUIDES.map((slug) => `/resources/${slug}`),
  ];

  return paths.flatMap((path) => [
    { url: `${site}${path || "/"}`, lastModified: now, changeFrequency: "daily" as const },
    { url: `${site}/es${path}`, lastModified: now, changeFrequency: "daily" as const },
  ]);
}
