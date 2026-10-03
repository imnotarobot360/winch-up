"use server";

import { after } from "next/server";

import { forwardGeocodePostalCode } from "@/lib/geocode-server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { supabaseServer } from "@/lib/supabase/server";

export type LocationActionResult = { ok: true } | { ok: false; error: string };

/**
 * Where a member says they are.
 *
 * Section 11 of the owner's geo-targeting spec. This is the ONLY write path to
 * `profiles.city/state/postal_code`, and it is two credentials doing two different jobs:
 *
 *   the member's session   `set_my_location()` reads auth.uid(), so the browser cannot name
 *                          somebody else's profile. It also normalizes the ZIP and CLEARS the
 *                          stored centroid.
 *   service_role           `set_member_postal_center()` writes the centroid the member is not
 *                          allowed to write, from a geocoder answer rather than from a claim.
 *
 * THIS IS NOT THE RECOVERY LOCATION. `responders.home_location` is what a call-out is measured
 * from, and section 7 forbids advertising from reading it. A member who has never volunteered has
 * no home_location and must still be reachable by a campaign; one who has must not have it
 * quietly repurposed. The two are separate columns for that reason and must stay separate.
 */
export async function setMyLocationAction(input: {
  city?: string | null;
  state?: string | null;
  postalCode?: string | null;
}): Promise<LocationActionResult> {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return { ok: false, error: "not_signed_in" };

  const { data, error } = await supabase.rpc("set_my_location", {
    p_city: input.city ?? null,
    p_state: input.state ?? null,
    p_postal_code: input.postalCode ?? null,
    p_country: "US",
  });

  if (error) {
    console.error("[location action] set_my_location failed", error);
    return { ok: false, error: "server_error" };
  }

  const result = data as { ok?: boolean; error?: string } | null;
  if (!result?.ok) return { ok: false, error: result?.error ?? "server_error" };

  /**
   * Geocode AFTER the answer has gone back to the member, never before it.
   *
   * The member's save must not wait on Mapbox and must not fail with it. A missing centroid is a
   * recoverable state by design -- the member matches no radius-targeted campaign until it is
   * filled in, which is the safe direction -- and `members_missing_postal_center()` exists so the
   * drain picks up whatever this misses. The same reasoning puts `reverseGeocodeCounty` after the
   * response in `createRequestAction`.
   */
  const postalCode = input.postalCode?.trim();
  if (postalCode) {
    after(async () => {
      try {
        const point = await forwardGeocodePostalCode(postalCode, input.state ?? null);
        if (!point) return;

        await supabaseAdmin().rpc("set_member_postal_center", {
          p_user_id: user.id,
          // Passed back so the database can refuse a late answer about a ZIP the member has since
          // changed. Do not "simplify" this away: without it a slow geocoder pins a stale point
          // onto a current postal code, which is exactly what clearing the column prevents.
          p_postal_code: postalCode,
          p_lng: point.lng,
          p_lat: point.lat,
        });
      } catch (error) {
        console.error("[location action] geocode failed", error);
      }
    });
  }

  return { ok: true };
}
