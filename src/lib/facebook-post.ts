import { mapAppUrl } from "@/lib/geo";
import type { StatusView } from "@/lib/types/status";

/**
 * Builds the post text in the shape the group admins already require.
 *
 * Facebook shut the Groups API down, so there is no way to post this automatically and no point
 * pretending otherwise. This produces text and a Copy button; a human pastes it.
 *
 * The header line is what the groups use to scan a feed: `#### Recovery Needed ####` while it is
 * open, `#### Recovered ####` once it is done — the same edit people make by hand today.
 */

export type PostLabels = {
  needed: string;
  recovered: string;
  cancelled: string;
  location: string;
  vehicle: string;
  situation: string;
  needs: string;
  notes: string;
  status: string;
  helper: string;
  postedVia: string;
  photos: string;
};

export function buildFacebookPost(
  status: StatusView,
  labels: PostLabels,
  enumLabel: (group: string, value: string) => string,
  statusUrl: string,
): string {
  const lines: string[] = [];

  const header =
    status.status === "recovered"
      ? labels.recovered
      : status.status === "cancelled" || status.status === "expired"
        ? labels.cancelled
        : labels.needed;

  lines.push(`#### ${header} ####`);
  lines.push("");

  const place = [
    `${status.lat.toFixed(5)}, ${status.lng.toFixed(5)}`,
    status.county ? `${status.county} County` : null,
  ]
    .filter(Boolean)
    .join(" — ");

  lines.push(`${labels.location}: ${place}`);
  lines.push(mapAppUrl(status.lat, status.lng));

  const vehicle = [
    status.vehicle.year ? String(status.vehicle.year) : null,
    status.vehicle.make,
    status.vehicle.model,
    enumLabel("vehicleClass", status.vehicle.class),
    status.vehicle.drivetrain !== "unknown"
      ? enumLabel("drivetrain", status.vehicle.drivetrain)
      : null,
  ]
    .filter(Boolean)
    .join(" ");

  lines.push(`${labels.vehicle}: ${vehicle}`);

  const situation = [
    enumLabel("stuckType", status.situation.stuck_type),
    status.situation.stuck_depth ? enumLabel("stuckDepth", status.situation.stuck_depth) : null,
    enumLabel("landType", status.situation.land_type),
  ]
    .filter(Boolean)
    .join(", ");

  lines.push(`${labels.situation}: ${situation}`);

  const needs = [
    status.situation.needs_tractor ? enumLabel("equipment", "tractor") : null,
    status.situation.needs_second_truck ? enumLabel("equipment", "second_truck") : null,
  ].filter(Boolean);

  if (needs.length > 0) {
    lines.push(`${labels.needs}: ${needs.join(", ")}`);
  }

  if (status.situation.notes) {
    lines.push(`${labels.notes}: ${status.situation.notes}`);
  }

  if (status.photos.length > 0) {
    lines.push(`${labels.photos}: ${status.photos.length}`);
  }

  if (status.responder && status.status !== "recovered") {
    lines.push(`${labels.helper}: ${status.responder.first_name}`);
  }

  lines.push("");

  // The status link is the whole point of pasting this: it is how the group finds out the job is
  // covered without a hundred "any update?" comments.
  lines.push(`${labels.status}: ${statusUrl}`);
  lines.push("");
  lines.push(`${labels.postedVia} ${status.short_code}`);

  return lines.join("\n");
}
