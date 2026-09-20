import { z } from "zod";

import { containsContactInfo } from "@/lib/contact-info";
import { isPlausibleCoordinate } from "@/lib/geo";

/**
 * The shape the /request wizard submits.
 *
 * This mirrors the CHECK constraints in supabase/migrations/20260920000400_tables.sql. The
 * database is still the enforcement point — this exists so the form can say what is wrong before
 * someone on one bar of signal spends a round trip finding out.
 */

export const LOCATION_SOURCES = [
  "gps",
  "map_pin",
  "coordinates",
  "google_maps_link",
  "what3words",
] as const;

export const VEHICLE_CLASSES = [
  "car",
  "suv",
  "truck",
  "jeep",
  "van",
  "utv_atv",
  "motorcycle",
  "rv_trailer",
  "semi",
  "other",
] as const;

export const STUCK_TYPES = [
  "mud",
  "sand",
  "water",
  "ditch",
  "rollover",
  "mechanical",
  "other",
] as const;

export const STUCK_DEPTHS = ["hubs", "frame", "buried"] as const;
export const DRIVETRAINS = ["2wd", "4wd", "awd", "unknown"] as const;
export const LAND_TYPES = ["public", "offroad_park", "private_permission"] as const;

const publicText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .refine((v) => !containsContactInfo(v), {
      message: "contact_info_not_allowed",
    });

export const photoSchema = z.object({
  path: z.string().min(1).max(400),
  contentType: z.enum(["image/jpeg", "image/png", "image/webp"]),
  bytes: z.number().int().positive().max(5 * 1024 * 1024).optional(),
  width: z.number().int().positive().optional(),
  height: z.number().int().positive().optional(),
});

export const requestSchema = z.object({
  submissionId: z.string().uuid(),
  locale: z.enum(["en", "es"]).default("en"),

  // The 911 gate. Not a formality: if this is false there is nothing to dispatch.
  emergencyAck: z.literal(true),

  lat: z.number(),
  lng: z.number(),
  accuracyM: z.number().nonnegative().max(100000).nullable().optional(),
  locationSource: z.enum(LOCATION_SOURCES),
  locationNote: publicText(200).nullable().optional(),

  photos: z.array(photoSchema).max(3).default([]),

  vehicleClass: z.enum(VEHICLE_CLASSES),
  vehicleMake: z.string().trim().max(40).nullable().optional(),
  vehicleModel: z.string().trim().max(40).nullable().optional(),
  vehicleYear: z.number().int().min(1900).max(2100).nullable().optional(),
  drivetrain: z.enum(DRIVETRAINS).default("unknown"),

  stuckType: z.enum(STUCK_TYPES),
  stuckDepth: z.enum(STUCK_DEPTHS).nullable().optional(),
  needsTractor: z.boolean().default(false),
  needsSecondTruck: z.boolean().default(false),

  landType: z.enum(LAND_TYPES),
  landPermissionNote: z.string().trim().max(200).nullable().optional(),
  notes: publicText(500).nullable().optional(),

  name: z.string().trim().min(1).max(60),
  phone: z.string().regex(/^\+1[0-9]{10}$/, "invalid_phone"),

  waiverAccepted: z.literal(true),
  rulesAccepted: z.literal(true),
});

export type RequestInput = z.infer<typeof requestSchema>;

export function validateRequest(raw: unknown) {
  const parsed = requestSchema.safeParse(raw);
  if (!parsed.success) return parsed;

  if (!isPlausibleCoordinate(parsed.data.lat, parsed.data.lng)) {
    return {
      success: false as const,
      error: new z.ZodError([
        {
          code: z.ZodIssueCode.custom,
          path: ["lat"],
          message: "invalid_location",
        },
      ]),
    };
  }

  return parsed;
}

/** camelCase form state in, snake_case jsonb for `public.create_request()` out. */
export function toRpcPayload(
  input: RequestInput,
  context: { ip: string | null; userAgent: string | null },
) {
  return {
    submission_id: input.submissionId,
    locale: input.locale,
    name: input.name,
    phone: input.phone,
    lat: input.lat,
    lng: input.lng,
    accuracy_m: input.accuracyM ?? null,
    location_source: input.locationSource,
    location_note: input.locationNote ?? null,
    vehicle_class: input.vehicleClass,
    vehicle_make: input.vehicleMake ?? null,
    vehicle_model: input.vehicleModel ?? null,
    vehicle_year: input.vehicleYear ?? null,
    drivetrain: input.drivetrain,
    stuck_type: input.stuckType,
    stuck_depth: input.stuckDepth ?? null,
    needs_tractor: input.needsTractor,
    needs_second_truck: input.needsSecondTruck,
    land_type: input.landType,
    land_permission_note: input.landPermissionNote ?? null,
    notes: input.notes ?? null,
    ip: context.ip,
    user_agent: context.userAgent?.slice(0, 400) ?? null,
    photos: input.photos.map((photo, index) => ({
      path: photo.path,
      content_type: photo.contentType,
      bytes: photo.bytes ?? null,
      width: photo.width ?? null,
      height: photo.height ?? null,
      sort_order: index,
    })),
  };
}
