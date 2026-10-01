/**
 * Where to send somebody after an OAuth round trip, and why it is a cookie.
 *
 * Supabase matches `redirect_to` against an EXACT allowlist in its dashboard. The bare callback
 * is on that list; the same URL carrying `?next=/account/security` is not, and Supabase does not
 * complain -- it silently falls back to the Site URL. The symptom is "it sent me to the wrong
 * page" with nothing in any log, and it has already cost a diagnosis on this project once.
 *
 * A cookie survives the round trip where a query string cannot: the return from the provider is
 * a top-level GET navigation, which carries SameSite=Lax cookies.
 *
 * THE VALUE IS UNTRUSTED. It is written by client JavaScript, so it is exactly as trustworthy as
 * a query parameter -- which is to say not at all -- and it ends up in a redirect. An open
 * redirect here would let a phishing link borrow this domain and its TLS certificate to bounce
 * somebody somewhere else, which is worth more to an attacker on a site people reach by SMS
 * link while stranded. Hence one validator, used by both the query string and the cookie.
 */

export const RETURN_COOKIE = "wu_after_auth";

/** Five minutes: long enough for a slow consent screen, short enough not to surprise later. */
export const RETURN_COOKIE_MAX_AGE = 300;

/**
 * A path this app will redirect to, or null.
 *
 * Accepts only same-site absolute paths. Everything else is refused rather than repaired,
 * because "clean it up and use it anyway" is how open redirects survive review.
 */
export function safeReturnPath(value: string | null | undefined): string | null {
  if (!value) return null;

  let path = value;

  // A cookie written with encodeURIComponent arrives encoded. Decoding can throw on a malformed
  // sequence, which is itself a good enough reason to refuse the value.
  try {
    path = decodeURIComponent(path);
  } catch {
    return null;
  }

  // Must be a path on this site.
  if (!path.startsWith("/")) return null;

  // "//evil.com" is protocol-relative: the browser reads it as another origin. So is "/\evil.com"
  // in several browsers, which is why the backslash is checked too rather than assumed harmless.
  if (path.startsWith("//") || path.startsWith("/\\")) return null;

  // A control character or a newline can smuggle a second header or break a parser downstream.
  if (/[\u0000-\u001f\u007f]/.test(path)) return null;

  return path;
}
