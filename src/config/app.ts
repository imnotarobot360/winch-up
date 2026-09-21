/**
 * The one place the product name lives.
 *
 * Rename here and everywhere follows: the i18n key `app.name` interpolates it, and no other
 * file is allowed to hard-code it.
 */
export const APP_NAME = "Winch Up";

/** Short form used in SMS, where every character costs money. */
export const APP_SHORT_NAME = "Winch Up";

export const SUPPORTED_LOCALES = ["en", "es"] as const;
export type Locale = (typeof SUPPORTED_LOCALES)[number];
export const DEFAULT_LOCALE: Locale = "en";

/** Display timezone for timestamps and the admin day view. */
export const DISPLAY_TIME_ZONE = "America/Chicago";

/**
 * Fallbacks that mirror the `app_settings` rows seeded in supabase/seed.sql.
 *
 * The database is the source of truth: read these through `get_public_settings()` at runtime.
 * These constants exist so the first paint has sensible numbers and so tests have something
 * to assert against without a database.
 */
export const DISPATCH_DEFAULTS = {
  ringRadiiMiles: [15, 30, 60] as const,
  ringWaitMinutes: 7,
  maxPerRing: 10,
  unmatchedAfterMinutes: 25,
  expireAfterHours: 24,
  tickSeconds: 60,
} as const;

export const LIMITS = {
  maxPhotos: 3,
  maxPhotoBytes: 5 * 1024 * 1024,
  maxRequestsPerPhonePerDay: 3,
  maxRequestsPerIpPerHour: 5,
  maxNotesChars: 500,
} as const;

export const BOARD = {
  /** Matches app_settings key `board.blur_miles`. */
  blurMiles: 1,
} as const;

/** Every enum value that reaches a screen. Keep in step with supabase/migrations/*_enums.sql. */
export const ENUMS = {
  stuckType: ["mud", "sand", "water", "ditch", "rollover", "mechanical", "other"],
  stuckDepth: ["hubs", "frame", "buried"],
  drivetrain: ["2wd", "4wd", "awd", "unknown"],
  landType: ["public", "offroad_park", "private_permission"],
  vehicleClass: [
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
  ],
  equipment: [
    "winch",
    "kinetic_rope",
    "traction_boards",
    "tractor",
    "second_truck",
    "trailer",
    "lifted_4x4",
    "night_lights",
  ],
  radiusMiles: [15, 30, 60],
} as const;
