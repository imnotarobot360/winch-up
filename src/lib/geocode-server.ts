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

/**
 * Turn a US postal code into the point at its middle.
 *
 * This exists for ONE purpose: radius targeting for adverts and events needs something to measure a
 * member's distance from, and the structured location a member states is a ZIP code rather than a
 * point. The recovery location (`responders.home_location`) is a real point and must never be used
 * for this — section 7 of the owner's spec forbids it, and the two are kept apart deliberately.
 *
 * A ZIP CENTROID IS COARSE AND THAT IS THE FEATURE. 77429 covers most of Cypress, so the answer is
 * "somewhere in this member's ZIP" rather than "this member's house", which is the right resolution
 * for deciding whether to show somebody an advert. Nothing here ever gets within a mile of where
 * anybody is, and `postal_center` is never served to another member.
 *
 * `state` narrows the search rather than filtering it. US ZIPs are unique nationally, so it is only
 * insurance against a geocoder matching the digits to a postcode in another country.
 */
export async function forwardGeocodePostalCode(
  postalCode: string,
  state?: string | null,
): Promise<{ lng: number; lat: number } | null> {
  const token = process.env.MAPBOX_SECRET_TOKEN ?? process.env.NEXT_PUBLIC_MAPBOX_TOKEN;
  if (!token) return null;

  // Five digits or nothing. The database constrains this too, but a geocoder is an outbound
  // request to a paid API and there is no reason to spend one on input that cannot be right.
  const zip = postalCode.trim();
  if (!/^[0-9]{5}$/.test(zip)) return null;

  const url = new URL("https://api.mapbox.com/search/geocode/v6/forward");
  url.searchParams.set("q", state ? `${zip}, ${state}` : zip);
  url.searchParams.set("types", "postcode");
  url.searchParams.set("country", "us");
  url.searchParams.set("limit", "1");
  url.searchParams.set("access_token", token);

  try {
    const response = await fetch(url.toString(), {
      signal: AbortSignal.timeout(5000),
    });

    if (!response.ok) return null;

    const payload = (await response.json()) as {
      features?: {
        properties?: {
          coordinates?: { longitude?: number; latitude?: number };
          context?: { postcode?: { name?: string } };
        };
      }[];
    };

    const feature = payload.features?.[0]?.properties;
    const lng = feature?.coordinates?.longitude;
    const lat = feature?.coordinates?.latitude;

    if (typeof lng !== "number" || typeof lat !== "number") return null;

    /**
     * CONFIRM THE ANSWER IS ABOUT THE ZIP WE ASKED FOR.
     *
     * Mapbox falls back to the nearest thing it can match rather than returning nothing, so a
     * five-digit string that is not a real postcode comes back as a confident point somewhere
     * else entirely. Storing that would put a member in a town they have never been to, and the
     * only symptom would be adverts reaching the wrong people — nothing on any screen would look
     * wrong. An answer about a different postcode is discarded.
     */
    const matched = payload.features?.[0]?.properties?.context?.postcode?.name;
    if (matched && matched.trim() !== zip) return null;

    return { lng, lat };
  } catch {
    return null;
  }
}
