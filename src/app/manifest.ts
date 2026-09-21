import type { MetadataRoute } from "next";

import { APP_NAME, APP_SHORT_NAME } from "@/config/app";

/**
 * Installable, so a volunteer can keep it on their home screen next to the group.
 *
 * `start_url` is the request page rather than the landing page: someone who installed this did
 * it because they expect to need it in a hurry.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: APP_NAME,
    short_name: APP_SHORT_NAME,
    description: "Volunteer off-road vehicle recovery in Texas.",
    start_url: "/request",
    scope: "/",
    display: "standalone",
    orientation: "portrait",
    background_color: "#0b2d1f",
    theme_color: "#0b2d1f",
    lang: "en",
    categories: ["utilities", "travel"],
    icons: [
      { src: "/icons/192", sizes: "192x192", type: "image/png", purpose: "any" },
      { src: "/icons/512", sizes: "512x512", type: "image/png", purpose: "any" },
      { src: "/icons/512", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
    shortcuts: [
      { name: "Get help", short_name: "Help", url: "/request" },
      { name: "Open board", short_name: "Board", url: "/board" },
      { name: "My jobs", short_name: "Jobs", url: "/me" },
    ],
  };
}
