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
  pro_options: ProOption[] | null;
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
