/**
 * Shapes returned by the SQL RPCs.
 *
 * Hand-written for now. Once the local stack is running, `npm run db:types` generates the table
 * types from the live schema; these RPC payload types stay here because they are shaped by the
 * functions, not the tables.
 */

export type RequestStatus =
  | "submitted"
  | "dispatching"
  | "unmatched"
  | "accepted"
  | "on_site"
  | "recovered"
  | "cancelled"
  | "expired";

export type RequestEventType =
  | "created"
  | "dispatch_started"
  | "ring_escalated"
  | "responder_notified"
  | "accepted"
  | "declined"
  | "on_site"
  | "recovered"
  | "cancelled"
  | "expired"
  | "unmatched"
  | "reassigned"
  | "thanked"
  | "admin_note";

export type TimelineEntry = {
  type: RequestEventType;
  at: string;
  data: Record<string, unknown>;
};

export type StatusResponder = {
  first_name: string;
  vehicle_class: string;
  vehicle_desc: string | null;
  /** Present only once the job has been accepted. */
  phone: string;
};

export type ProOption = {
  name: string;
  phone: string | null;
  url: string | null;
  blurb: string | null;
};

export type StatusPayload = {
  id: string;
  short_code: string;
  status: RequestStatus;
  locale: "en" | "es";
  created_at: string;
  requester_name: string;
  lat: number;
  lng: number;
  accuracy_m: number | null;
  county: string | null;
  vehicle: {
    class: string;
    make: string | null;
    model: string | null;
    year: number | null;
    drivetrain: string;
  };
  situation: {
    stuck_type: string;
    stuck_depth: string | null;
    needs_tractor: boolean;
    needs_second_truck: boolean;
    land_type: string;
    notes: string | null;
  };
  dispatch: {
    current_ring: number;
    radius_miles: number | null;
    notified_count: number;
    started_at: string | null;
    unmatched_at: string | null;
  };
  eta_minutes: number | null;
  on_site_at: string | null;
  recovered_at: string | null;
  cancelled_at: string | null;
  thanked: boolean;
  photos: { path: string; sort: number }[];
  timeline: TimelineEntry[];
  responder: StatusResponder | null;
  /**
   * Volunteers who have put their hand up and are waiting to be chosen (spec section 8, steps 4
   * and 5). Empty once somebody is accepted -- `responder` is the answer from then on.
   *
   * No phone number here, deliberately. Contact details are released in one direction at one
   * moment, and that moment is acceptance. This list is also visible to anyone holding the
   * status link, which gets forwarded around, so it carries a first name and a vehicle and
   * nothing that would let a stranger reach a volunteer directly.
   */
  offers: StatusOffer[];
  /**
   * Everybody still on the recovery (spec section 4). Names, vehicles and kit; no phone numbers.
   * `responder` below is still the lead and still the only place a number is released.
   */
  team: StatusTeamMember[];
  pro_options: ProOption[] | null;
};

export type StatusTeamMember = {
  role: "requester" | "helper";
  status: string;
  name: string | null;
  vehicle: string | null;
  equipment: string[] | null;
  joined_at: string;
};

export type StatusOffer = {
  id: string;
  first_name: string;
  vehicle_class: string;
  vehicle_desc: string | null;
  distance_miles: number | null;
  eta_minutes: number | null;
  note: string | null;
  origin: "ring" | "self";
  /** An admin has checked them. A badge, not a gate -- see 20260923000100_universal_membership. */
  verified: boolean;
  offered_at: string;
};

/** Status page payload plus the signed photo URLs the server minted for this render. */
export type StatusView = StatusPayload & {
  photo_urls: string[];
};

export const OPEN_STATUSES: RequestStatus[] = [
  "submitted",
  "dispatching",
  "unmatched",
  "accepted",
  "on_site",
];

export function isClosed(status: RequestStatus): boolean {
  return !OPEN_STATUSES.includes(status);
}
