import type { MetadataRoute } from "next";

/**
 * The landing page and the board are worth finding. Nothing else is.
 *
 * `/r/` and `/post/` carry unguessable tokens and get forwarded around by the people helping,
 * so they must never end up in an index. `/me` and `/admin` are behind a session anyway, but say
 * so explicitly.
 */
export default function robots(): MetadataRoute.Robots {
  const site = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "");

  return {
    rules: [
      {
        userAgent: "*",
        allow: ["/", "/board", "/join", "/terms", "/waiver", "/privacy"],
        disallow: ["/r/", "/post/", "/me", "/admin", "/api/"],
      },
    ],
    sitemap: site ? `${site}/sitemap.xml` : undefined,
  };
}
