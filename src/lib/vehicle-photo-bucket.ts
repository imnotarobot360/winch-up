/**
 * The rig-photo bucket name, in its own module.
 *
 * `lib/supabase/admin.ts` is "server-only" and importing it from a client component is a build
 * error. The garage screen signs its own read URLs in the browser, so it needs the name too --
 * and a bucket name is not a secret, it is a string that both sides have to agree on. One
 * definition, imported by both, rather than the same literal typed twice.
 */
export const VEHICLE_PHOTO_BUCKET = "vehicle-photos";
