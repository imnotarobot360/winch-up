/**
 * Client-side twin of `public.contains_contact_info()` in
 * supabase/migrations/20260920000300_helpers.sql.
 *
 * The database is the enforcement point — this exists only so someone typing their phone number
 * into the public notes field finds out while they are still typing, instead of losing the form
 * to a constraint violation on submit.
 *
 * Keep the patterns identical to the SQL. If you change one, change both and update the parity
 * test in supabase/tests/privacy_rls_test.sql.
 */

const PHONE_SHAPE = /(\+?1[ .-]?)?\(?[0-9]{3}\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}/;
const LONG_DIGIT_RUN = /[0-9]{10,}/;
const EXPLICIT_URL = /(https?:\/\/|www\.)/i;
const BARE_DOMAIN =
  /[a-z0-9][a-z0-9-]*\.(com|net|org|io|co|us|info|biz|me|link|tv|shop)(\/|\?|$|[ ,.;])/i;

export function containsContactInfo(text: string | null | undefined): boolean {
  if (!text) return false;
  return (
    PHONE_SHAPE.test(text) ||
    LONG_DIGIT_RUN.test(text) ||
    EXPLICIT_URL.test(text) ||
    BARE_DOMAIN.test(text)
  );
}
