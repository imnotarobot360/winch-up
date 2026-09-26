/**
 * The one place the product name lives.
 *
 * Rename here and everywhere follows: the i18n key `app.name` interpolates it, and no other
 * file is allowed to hard-code it.
 */
export const APP_NAME = "Winch Up";

/** Short form used in SMS, where every character costs money. */
export const APP_SHORT_NAME = "Winch Up";

/**
 * The legal entity, which is not the product name.
 *
 * Kept separate on purpose: APP_NAME is what the app calls itself and can be renamed freely,
 * while this is a registered company and changing it is a filing, not a decision. It belongs in
 * exactly two kinds of place -- the legal pages, and anything checked against public records.
 *
 * A2P 10DLC brand verification compares the name on the campaign against the name on the privacy
 * policy and terms, so if the registered brand ever changes, this is the one line to change and
 * the legal pages follow.
 */
export const LEGAL_ENTITY = "Winch Up LLC";

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
  recoveryPoints: ["none", "front", "rear", "both", "unknown"],

  equipment: [
    "winch",
    "kinetic_rope",
    "traction_boards",
    "tractor",
    "second_truck",
    "trailer",
    "lifted_4x4",
    "night_lights",
    "soft_shackles",
    "rated_recovery_points",
    "air_compressor",
    "tire_repair",
    "jack_lifting",
  ],
  radiusMiles: [15, 30, 60],
} as const;
