/**
 * The member-avatar bucket name, in its own module.
 *
 * Same reasoning as `vehicle-photo-bucket.ts`: `lib/supabase/admin.ts` is "server-only" and
 * importing it from a client component is a build error, while the account screen needs the name
 * to upload. A bucket name is not a secret -- it is a string both sides have to agree on -- so it
 * gets one definition rather than being typed twice.
 */
export const AVATAR_BUCKET = "member-avatars";
