import "server-only";

/**
 * Work out which county a pin is in.
 *
 * The groups describe locations by county — "Montgomery County, off the pipeline cut" — so the
 * offer text a volunteer gets is materially better with it than without. Mapbox calls a US
 * county a `district`.
 *
 * This is never on the critical path: `createRequestAction` runs it after the response has gone
 * out, and a failure leaves `county` null, which every template already handles.
 */
export async function reverseGeocodeCounty(
  lat: number,
  lng: number,
): Promise<string | null> {
  const token = process.env.MAPBOX_SECRET_TOKEN ?? process.env.NEXT_PUBLIC_MAPBOX_TOKEN;
  if (!token) return null;

  const url = new URL("https://api.mapbox.com/search/geocode/v6/reverse");
  url.searchParams.set("longitude", String(lng));
  url.searchParams.set("latitude", String(lat));
  url.searchParams.set("types", "district");
  url.searchParams.set("access_token", token);

  try {
    const response = await fetch(url.toString(), {
      signal: AbortSignal.timeout(5000),
    });

    if (!response.ok) return null;

    const payload = (await response.json()) as {
      features?: { properties?: { name?: string } }[];
    };

    const name = payload.features?.[0]?.properties?.name;
    if (!name) return null;

    // Mapbox returns "Montgomery County"; the SMS templates and the board add the word
    // "County" themselves, so store the bare name.
    return name.replace(/\s+County$/i, "").slice(0, 60);
  } catch {
    return null;
  }
}
