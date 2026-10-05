/**
 * Filling the placeholders in a push notification's title.
 *
 * WHY THIS EXISTS. `drainPush` looked its copy up by key and used the string RAW. Every push whose
 * message carries a placeholder therefore rendered the braces on the lock screen: a direct message
 * arrived as the literal text "{name} sent you a message". The database had always passed the
 * parameters, `claim_push_deliveries` had always returned them, and the drain read the field into a
 * typed property and then never used it. Nothing failed, nothing was logged, and no test covered
 * the one line that mattered -- the copy was correct, the data was correct, and the two were never
 * introduced.
 *
 * It is a module of its own rather than a function inside send.ts because send.ts is `server-only`
 * and vitest has no alias for that, so anything in there cannot be unit tested at all. A pure
 * helper beside it can be, which is the same split as `contact-info.ts` and `observability/scrub.ts`.
 *
 * A MISSING PARAMETER LEAVES ITS PLACEHOLDER rather than printing "undefined" or quietly blanking.
 * Blanking reads as a finished sentence -- "sent you a message" -- so a notification that lost its
 * name would look deliberate and nobody would ever notice. Visible braces are ugly exactly once and
 * then get fixed. That is a direct lesson from the bug above, which survived because its failure
 * mode looked like a design choice.
 */

/**
 * Substitutes `{key}` in `template` from `params`.
 *
 * Single pass: a value is never re-scanned for placeholders, so a member whose display name is
 * literally "{name}" cannot make their own name expand into anything.
 */
export function interpolate(template: string, params: Record<string, unknown> | null): string {
  if (!params) return template;

  return template.replace(/\{(\w+)\}/g, (placeholder, key: string) => {
    const value = params[key];
    if (value === undefined || value === null || value === "") return placeholder;
    return String(value);
  });
}
