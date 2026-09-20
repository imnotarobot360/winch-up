/**
 * Turning whatever someone pastes into a coordinate.
 *
 * This is the fallback path for when GPS is refused, wrong, or the phone has no fix. It has to
 * handle what people actually send each other in the Facebook groups: a Google Maps link, a
 * screenshot's worth of coordinates typed by hand, a geo: URI from a share sheet, or a
 * what3words address.
 */

export type ParsedLocation =
  | { kind: "coords"; lat: number; lng: number; source: LocationSource }
  | { kind: "short_link"; url: string }
  | { kind: "what3words"; words: string }
  | { kind: "none" };

export type LocationSource =
  | "gps"
  | "map_pin"
  | "coordinates"
  | "google_maps_link"
  | "what3words"
  | "admin_intake";

/** Texas, generously bounded. A pin outside this is almost always a typo or a swapped pair. */
export const TEXAS_BOUNDS = {
  minLat: 25.5,
  maxLat: 36.8,
  minLng: -107.0,
  maxLng: -93.0,
};

export function isPlausibleCoordinate(lat: number, lng: number): boolean {
  return (
    Number.isFinite(lat) &&
    Number.isFinite(lng) &&
    lat >= -90 &&
    lat <= 90 &&
    lng >= -180 &&
    lng <= 180 &&
    !(lat === 0 && lng === 0)
  );
}

export function isInTexasish(lat: number, lng: number): boolean {
  return (
    lat >= TEXAS_BOUNDS.minLat &&
    lat <= TEXAS_BOUNDS.maxLat &&
    lng >= TEXAS_BOUNDS.minLng &&
    lng <= TEXAS_BOUNDS.maxLng
  );
}

const DECIMAL_PAIR = /(-?\d{1,3}(?:\.\d+)?)[ ,]+(-?\d{1,3}(?:\.\d+)?)/;

const DMS =
  /(\d{1,3})[°\s]+(\d{1,2})['′\s]+(\d{1,2}(?:\.\d+)?)["″\s]*([NSEW])/gi;

function dmsToDecimal(deg: number, min: number, sec: number, hemi: string): number {
  const value = deg + min / 60 + sec / 3600;
  return hemi.toUpperCase() === "S" || hemi.toUpperCase() === "W" ? -value : value;
}

/** "29°45'37.4"N 95°22'11.3"W" */
function parseDms(text: string): { lat: number; lng: number } | null {
  const matches = [...text.matchAll(DMS)];
  if (matches.length < 2) return null;

  const values = matches.map((m) =>
    dmsToDecimal(Number(m[1]), Number(m[2]), Number(m[3]), m[4]),
  );
  const hemis = matches.map((m) => m[4].toUpperCase());

  const latIndex = hemis.findIndex((h) => h === "N" || h === "S");
  const lngIndex = hemis.findIndex((h) => h === "E" || h === "W");
  if (latIndex === -1 || lngIndex === -1) return null;

  return { lat: values[latIndex], lng: values[lngIndex] };
}

/** "29.7604, -95.3698" and the geo: URI a share sheet produces. */
function parseDecimal(text: string): { lat: number; lng: number } | null {
  const cleaned = text.replace(/^geo:/i, "").replace(/\?.*$/, "");
  const m = DECIMAL_PAIR.exec(cleaned);
  if (!m) return null;

  const lat = Number(m[1]);
  const lng = Number(m[2]);
  if (!isPlausibleCoordinate(lat, lng)) return null;
  return { lat, lng };
}

/**
 * Google Maps links, in the shapes people actually paste:
 *   /maps/@29.7604,-95.3698,15z
 *   /maps/place/Name/@29.7604,-95.3698,17z/...
 *   ?q=29.7604,-95.3698  or  ?ll=  or  ?destination=
 * Short goo.gl links carry no coordinates and have to be followed server-side.
 */
function parseGoogleMaps(text: string): ParsedLocation | null {
  let url: URL;
  try {
    url = new URL(text.trim());
  } catch {
    return null;
  }

  const host = url.hostname.toLowerCase();
  const isGoogleMaps =
    host.endsWith("google.com") ||
    host.endsWith("google.co.uk") ||
    host === "maps.app.goo.gl" ||
    host === "goo.gl";

  if (!isGoogleMaps) return null;

  if (host === "maps.app.goo.gl" || host === "goo.gl") {
    return { kind: "short_link", url: url.toString() };
  }

  const at = /@(-?\d+\.\d+),(-?\d+\.\d+)/.exec(url.pathname + url.search);
  if (at) {
    const lat = Number(at[1]);
    const lng = Number(at[2]);
    if (isPlausibleCoordinate(lat, lng)) {
      return { kind: "coords", lat, lng, source: "google_maps_link" };
    }
  }

  for (const key of ["q", "ll", "destination", "daddr", "center"]) {
    const value = url.searchParams.get(key);
    if (!value) continue;
    const parsed = parseDecimal(value);
    if (parsed) {
      return { kind: "coords", ...parsed, source: "google_maps_link" };
    }
  }

  return null;
}

const W3W = /^\/{0,3}([a-z]{3,}\.[a-z]{3,}\.[a-z]{3,})$/i;

export function parseLocationInput(raw: string): ParsedLocation {
  const text = raw.trim();
  if (!text) return { kind: "none" };

  const gmaps = parseGoogleMaps(text);
  if (gmaps) return gmaps;

  const w3w = W3W.exec(text);
  if (w3w) return { kind: "what3words", words: w3w[1].toLowerCase() };

  const dms = parseDms(text);
  if (dms && isPlausibleCoordinate(dms.lat, dms.lng)) {
    return { kind: "coords", ...dms, source: "coordinates" };
  }

  const decimal = parseDecimal(text);
  if (decimal) return { kind: "coords", ...decimal, source: "coordinates" };

  return { kind: "none" };
}

/** Straight-line miles. Good enough for "12 mi from you" in a text message. */
export function haversineMiles(
  a: { lat: number; lng: number },
  b: { lat: number; lng: number },
): number {
  const R = 3958.7613;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);

  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;

  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

export function formatCoords(lat: number, lng: number): string {
  return `${lat.toFixed(5)}, ${lng.toFixed(5)}`;
}

/** Universal link: opens the native map app on Android and iOS, the web map otherwise. */
export function mapAppUrl(lat: number, lng: number): string {
  return `https://www.google.com/maps/search/?api=1&query=${lat},${lng}`;
}
