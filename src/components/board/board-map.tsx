"use client";

// Mapbox GL's own stylesheet. Without it the canvas draws but every control, marker and the
// attribution are unpositioned, and the library warns about it in the console on every load --
// "This page appears to be missing CSS declarations for Mapbox GL JS". map-picker.tsx has always
// imported it; this file never did, so the board map has been subtly wrong since it was written.
// Importing in both is correct: bundlers deduplicate it, and neither component should depend on
// the other having been loaded first.
import "mapbox-gl/dist/mapbox-gl.css";

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";

import type { BoardRow } from "./board-list";

const OPEN = ["submitted", "dispatching", "unmatched"];

/**
 * The board as a map.
 *
 * Every pin here is the blurred one the board already serves -- about a mile off and stable, so
 * repeated loads cannot be averaged back to a real address. This component never sees an exact
 * location, which is the point: there is no code path from the public map to a real pin.
 *
 * Degrades to a notice when NEXT_PUBLIC_MAPBOX_TOKEN is absent, the same way the request wizard's
 * picker does, so a missing token is a missing map rather than a broken page.
 *
 * `fill` is for the home dashboard, where the map is the screen rather than a card on it: no
 * border, no corner radius, and it takes the height of whatever contains it. On /board it stays
 * a bordered panel with a minimum height, because there it sits in a column with other things.
 */
export function BoardMap({ rows, fill = false }: { rows: BoardRow[]; fill?: boolean }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [failed, setFailed] = useState(false);
  const t = useTranslations("board");

  useEffect(() => {
    const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN;
    if (!token || !containerRef.current) {
      setFailed(true);
      return;
    }

    let map: { remove: () => void } | null = null;
    let cancelled = false;

    (async () => {
      try {
        const mapboxgl = (await import("mapbox-gl")).default;
        if (cancelled || !containerRef.current) return;

        mapboxgl.accessToken = token;

        // Dark style: a light map inside a dark app reads as a hole punched in the screen, and
        // at night it is the brightest thing on a phone held at arm's length.
        const instance = new mapboxgl.Map({
          container: containerRef.current,
          style: "mapbox://styles/mapbox/dark-v11",
          center: [-97.7431, 31.0], // Texas
          zoom: 5.2,
          attributionControl: true,
        });

        // A token that exists but is rejected -- revoked, expired, or URL-restricted to a domain
        // this is not being served from -- fails AFTER construction, so the absent-token guard
        // above never sees it. Without this the map draws an empty grey box that looks like a
        // working map of nowhere, which is exactly what happened when the token was restricted.
        // Caught here it becomes the same honest notice a missing token gives.
        instance.on("error", (event) => {
          const status = (event.error as Error & { status?: number })?.status;
          if ((status === 401 || status === 403) && !cancelled) setFailed(true);
        });

        instance.addControl(new mapboxgl.NavigationControl({ showCompass: false }), "top-right");

        const bounds = new mapboxgl.LngLatBounds();

        for (const row of rows) {
          const el = document.createElement("div");
          el.className = "winchup-pin";
          el.style.cssText = [
            "width:18px", "height:18px", "border-radius:9999px",
            `background:${OPEN.includes(row.status) ? "#ff6a00" : "#5fd39b"}`,
            "border:3px solid #08150f",
            "box-shadow:0 0 0 1px rgba(255,255,255,.35)",
          ].join(";");
          el.setAttribute("aria-label", row.short_code);

          new mapboxgl.Marker({ element: el })
            .setLngLat([row.lng, row.lat])
            .setPopup(new mapboxgl.Popup({ offset: 14, closeButton: false })
              .setText(`${row.short_code} · ${row.county ?? ""} ${row.state}`.trim()))
            .addTo(instance);

          bounds.extend([row.lng, row.lat]);
        }

        if (rows.length > 0) {
          instance.fitBounds(bounds, { padding: 64, maxZoom: 11, duration: 0 });
        }

        map = instance;
      } catch {
        if (!cancelled) setFailed(true);
      }
    })();

    return () => {
      cancelled = true;
      map?.remove();
    };
  }, [rows]);

  if (failed) {
    return (
      <div
        className={`flex items-center justify-center bg-surface-sunk p-6 text-center text-ink-soft ${
          fill ? "h-full" : "min-h-64 rounded-field border-2 border-line"
        }`}
      >
        {t("mapUnavailable")}
      </div>
    );
  }

  return (
    <div
      ref={containerRef}
      role="application"
      aria-label={t("mapLabel")}
      className={
        fill
          ? "h-full w-full"
          : "min-h-[24rem] w-full overflow-hidden rounded-field border-2 border-line"
      }
    />
  );
}
