"use client";

import "mapbox-gl/dist/mapbox-gl.css";

import type { Map as MapboxMap, Marker as MapboxMarker } from "mapbox-gl";
import { useCallback, useEffect, useRef, useState } from "react";

import { formatCoords } from "@/lib/geo";

/**
 * Pick the recovery point on a map.
 *
 * THREE WAYS TO MOVE THE PIN, BECAUSE ONE IS NOT ENOUGH
 *
 * Pan the map under a fixed crosshair, tap where you are, or drag the pin. They exist for
 * different hands: panning is what works one-handed next to a stuck truck, tapping is faster on a
 * desktop with a mouse, and dragging is what most people try first because every other map app
 * does it. All three write to the same coordinates, so there is no "real" one.
 *
 * SATELLITE MATTERS MORE THAN IT LOOKS
 *
 * This is off-road recovery. A street map of a ranch road shows a grey line through nothing; the
 * satellite image shows the creek crossing, the treeline and which side of the fence you are on.
 * The toggle keeps the pin and the viewport across a style change -- Mapbox drops custom layers
 * when the style swaps, so the marker is re-added on styledata rather than assumed to survive.
 *
 * NOTHING IS SAVED UNTIL IT IS CONFIRMED
 *
 * The picker reports its pin as it moves, but the caller treats that as provisional. Confirming
 * is a separate, deliberate press: a coordinate that gets saved because somebody's thumb brushed
 * the map is worse than one they had to agree to, and this is the value a volunteer drives to.
 *
 * Mapbox GL is imported dynamically so a phone that cannot fetch it still gets a working form --
 * the caller keeps paste-coordinates visible either way.
 */

type LngLat = { lat: number; lng: number };

type Props = {
  lat: number;
  lng: number;
  /** Fires as the pin moves. Provisional: the caller should not save it yet. */
  onChange: (next: LngLat) => void;
  /** Fires when the member presses confirm. This is the one that counts. */
  onConfirm: (next: LngLat) => void;
  label: string;
  unavailableLabel: string;
  retryLabel: string;
  confirmLabel: string;
  standardLabel: string;
  satelliteLabel: string;
  /** Already-confirmed coordinates, so the button can say so instead of nagging. */
  confirmed: LngLat | null;
  confirmedLabel: string;
};

const STYLES = {
  // Streets first: it is the cheaper tile load and the one that reads on a bad connection.
  standard: "mapbox://styles/mapbox/streets-v12",
  satellite: "mapbox://styles/mapbox/satellite-streets-v12",
} as const;

type StyleKey = keyof typeof STYLES;

function same(a: LngLat | null, b: LngLat): boolean {
  if (!a) return false;
  // Six decimals is about 11cm. Beyond that it is float noise, not a different place.
  return a.lat.toFixed(6) === b.lat.toFixed(6) && a.lng.toFixed(6) === b.lng.toFixed(6);
}

export function MapPicker({
  lat,
  lng,
  onChange,
  onConfirm,
  label,
  unavailableLabel,
  retryLabel,
  confirmLabel,
  standardLabel,
  satelliteLabel,
  confirmed,
  confirmedLabel,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MapboxMap | null>(null);
  const markerRef = useRef<MapboxMarker | null>(null);
  const [failed, setFailed] = useState(false);
  const [center, setCenter] = useState<LngLat>({ lat, lng });
  const [style, setStyle] = useState<StyleKey>("satellite");
  // Bumped by Retry. Re-running the effect is the retry; there is no separate teardown path to
  // get wrong.
  const [attempt, setAttempt] = useState(0);

  // onChange in a ref so the map effect can stay mounted-once. Putting it in the dependency list
  // re-creates the map whenever the parent re-renders, which fights the member's panning -- the
  // original bug this file's comment warned about.
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  const move = useCallback((next: LngLat) => {
    setCenter(next);
    onChangeRef.current(next);
  }, []);

  useEffect(() => {
    const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN;
    if (!token || !containerRef.current) {
      setFailed(true);
      return;
    }

    let cancelled = false;
    setFailed(false);

    (async () => {
      try {
        const mapboxgl = (await import("mapbox-gl")).default;
        if (cancelled || !containerRef.current) return;

        mapboxgl.accessToken = token;

        const instance = new mapboxgl.Map({
          container: containerRef.current,
          style: STYLES[style],
          center: [lng, lat],
          zoom: 15,
          attributionControl: true,
        });

        // A failure after construction -- a rejected token, a tile 403 -- surfaces here rather
        // than as a blank grey box that looks like a working map with nothing on it.
        instance.on("error", (event) => {
          // Mapbox types this as a plain Error; a tile or token rejection hangs `status` off it.
          // 401/403 is the token being absent, wrong, or restricted to another domain -- the
          // cases where retrying the same request cannot help and the fallback should show.
          const status = (event.error as Error & { status?: number })?.status;
          if (status === 401 || status === 403) {
            if (!cancelled) setFailed(true);
          }
        });

        instance.addControl(new mapboxgl.NavigationControl({ showCompass: false }), "top-right");

        const marker = new mapboxgl.Marker({ color: "#f97316", draggable: true })
          .setLngLat([lng, lat])
          .addTo(instance);

        marker.on("dragend", () => {
          const p = marker.getLngLat();
          instance.easeTo({ center: p, duration: 200 });
          move({ lat: p.lat, lng: p.lng });
        });

        instance.on("click", (event) => {
          const p = event.lngLat;
          marker.setLngLat([p.lng, p.lat]);
          instance.easeTo({ center: [p.lng, p.lat], duration: 200 });
          move({ lat: p.lat, lng: p.lng });
        });

        // Panning under the crosshair. moveend rather than move: one write per gesture instead of
        // one per frame.
        instance.on("moveend", () => {
          const c = instance.getCenter();
          marker.setLngLat(c);
          move({ lat: c.lat, lng: c.lng });
        });

        // A style swap wipes markers. Put it back where it was, not where the map started.
        instance.on("styledata", () => {
          if (cancelled) return;
          const c = instance.getCenter();
          marker.setLngLat(c).addTo(instance);
        });

        mapRef.current = instance;
        markerRef.current = marker;
      } catch {
        if (!cancelled) setFailed(true);
      }
    })();

    return () => {
      cancelled = true;
      mapRef.current?.remove();
      mapRef.current = null;
      markerRef.current = null;
    };
    // style and attempt intentionally excluded: switching style is handled in place below, and
    // re-mounting for it would lose the viewport. `attempt` is in the list because retrying IS a
    // remount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [attempt, move]);

  function switchStyle(next: StyleKey) {
    setStyle(next);
    // setStyle on the live map keeps centre, zoom and the marker (re-added on styledata), which
    // is the whole requirement: changing the view must not lose the chosen point.
    mapRef.current?.setStyle(STYLES[next]);
  }

  if (failed) {
    return (
      <div className="space-y-3 rounded-field border-2 border-line bg-surface-sunk p-4">
        <p className="text-base text-ink-soft">{unavailableLabel}</p>
        <button
          type="button"
          onClick={() => setAttempt((n) => n + 1)}
          className="tap-target rounded-field border-2 border-line px-4 text-base font-semibold"
        >
          {retryLabel}
        </button>
      </div>
    );
  }

  const isConfirmed = same(confirmed, center);

  return (
    <div className="space-y-2">
      <div className="flex gap-2" role="group" aria-label={label}>
        {(
          [
            ["standard", standardLabel],
            ["satellite", satelliteLabel],
          ] as [StyleKey, string][]
        ).map(([key, text]) => (
          <button
            key={key}
            type="button"
            aria-pressed={style === key}
            onClick={() => switchStyle(key)}
            className={`tap-target flex-1 rounded-field border-2 px-3 text-base font-semibold ${
              style === key ? "border-brand bg-brand-tint" : "border-line"
            }`}
          >
            {text}
          </button>
        ))}
      </div>

      <div className="relative h-72 w-full overflow-hidden rounded-field border-2 border-line">
        <div ref={containerRef} className="h-full w-full" aria-label={label} role="application" />
        {/* The crosshair sits above the map and never moves. Non-interactive so it cannot eat the
            taps that are meant to place the pin. */}
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

      <button
        type="button"
        onClick={() => onConfirm(center)}
        disabled={isConfirmed}
        className={`tap-target w-full rounded-field border-2 px-4 text-lg font-semibold ${
          isConfirmed ? "border-good bg-good-tint text-good" : "border-brand bg-brand text-white"
        }`}
      >
        {isConfirmed ? confirmedLabel : confirmLabel}
      </button>
    </div>
  );
}
