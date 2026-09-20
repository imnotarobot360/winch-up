import { isPlausibleCoordinate } from "@/lib/geo";

export type GeocodeResult = {
  lat: number;
  lng: number;
  label: string;
};

/**
 * Forward-geocode a volunteer's home address with Mapbox.
 *
 * Runs in the browser with the public token, biased to Texas. Volunteers type a town or a cross
 * street, not coordinates, and the result only has to be good enough to measure a 15-60 mile
 * radius from.
 */
export async function geocodeAddress(query: string): Promise<GeocodeResult | null> {
  const token = process.env.NEXT_PUBLIC_MAPBOX_TOKEN;
  if (!token || query.trim().length < 3) return null;

  const url = new URL("https://api.mapbox.com/search/geocode/v6/forward");
  url.searchParams.set("q", query.trim());
  url.searchParams.set("country", "us");
  url.searchParams.set("proximity", "-95.4,30.0");
  url.searchParams.set("limit", "1");
  url.searchParams.set("access_token", token);

  const response = await fetch(url.toString());
  if (!response.ok) return null;

  const payload = (await response.json()) as {
    features?: {
      properties?: { full_address?: string; name?: string };
      geometry?: { coordinates?: [number, number] };
    }[];
  };

  const feature = payload.features?.[0];
  const coordinates = feature?.geometry?.coordinates;
  if (!coordinates) return null;

  const [lng, lat] = coordinates;
  if (!isPlausibleCoordinate(lat, lng)) return null;

  return {
    lat,
    lng,
    label: feature?.properties?.full_address ?? feature?.properties?.name ?? query,
  };
}
