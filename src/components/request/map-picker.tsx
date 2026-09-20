"use client";

import "mapbox-gl/dist/mapbox-gl.css";

import { useEffect, useRef, useState } from "react";

import { formatCoords } from "@/lib/geo";

/**
 * Fixed-crosshair map picker: the pin is always the centre of the map, and you move the map
 * under it. Dragging a marker with a thumb, one-handed, next to a stuck truck, is fiddly;
 * panning is not.
 *
 * Mapbox GL is loaded dynamically so that a phone that cannot fetch it still gets a working
 * form — the caller keeps the paste-coordinates fallback visible either way.
 */

type Props = {
  lat: number;
  lng: number;
  onChange: (next: { lat: number; lng: number }) => void;
  label: string;
  unavailableLabel: string;
};

export function MapPicker({ lat, lng, onChange, label, unavailableLabel }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [failed, setFailed] = useState(false);
  const [center, setCenter] = useState({ lat, lng });

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

        const instance = new mapboxgl.Map({
          container: containerRef.current,
          style: "mapbox://styles/mapbox/satellite-streets-v12",
          center: [lng, lat],
          zoom: 15,
          attributionControl: true,
        });

        instance.addControl(new mapboxgl.NavigationControl({ showCompass: false }), "top-right");

        instance.on("moveend", () => {
          const next = instance.getCenter();
          const value = { lat: next.lat, lng: next.lng };
          setCenter(value);
          onChange(value);
        });

        map = instance;
      } catch {
        if (!cancelled) setFailed(true);
      }
    })();

    return () => {
      cancelled = true;
      map?.remove();
    };
    // Deliberately mounts once: re-creating the map on every coordinate change would fight the
    // user's panning.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (failed) {
    return (
      <p className="rounded-field border-2 border-line bg-surface-sunk p-4 text-base text-ink-soft">
        {unavailableLabel}
      </p>
    );
  }

  return (
    <div className="space-y-2">
      <div className="relative h-72 w-full overflow-hidden rounded-field border-2 border-line">
        <div ref={containerRef} className="h-full w-full" aria-label={label} role="application" />
        {/* The crosshair sits above the map and never moves. */}
        <div
          aria-hidden
          className="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-full"
        >
          <svg width="36" height="46" viewBox="0 0 36 46" fill="none">
            <path
              d="M18 45C18 45 33 28.5 33 18C33 9.7 26.3 3 18 3C9.7 3 3 9.7 3 18C3 28.5 18 45 18 45Z"
              fill="var(--color-brand)"
              stroke="white"
              strokeWidth="3"
            />
            <circle cx="18" cy="18" r="5" fill="white" />
          </svg>
        </div>
      </div>
      <p className="text-center font-mono text-sm text-ink-soft">
        {formatCoords(center.lat, center.lng)}
      </p>
    </div>
  );
}
