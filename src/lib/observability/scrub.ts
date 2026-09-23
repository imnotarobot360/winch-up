/**
 * Take everything about a person out of an error report before it leaves the building.
 *
 * Error tracking is a privacy surface, and in this app a sharper one than usual. The things that
 * go wrong here go wrong while somebody is stuck: the crash report is exactly where a phone
 * number, an exact set of coordinates, or a status token most wants to end up. A status token is
 * the worst of the three — it is the key to a live recovery, and anyone with access to the error
 * dashboard could paste it into a browser and watch.
 *
 * So nothing reaches the tracker that has not been through here. This is a denylist, which is
 * never perfect, so it is deliberately aggressive: it would rather redact a harmless order number
 * than let one phone number through. An error report with `[redacted]` in it is still enough to
 * find a bug. An error report with somebody's location in it is a breach.
 *
 * Paired with `sendDefaultPii: false` and no session replay, which is not a setting so much as a
 * refusal — a replay of the request wizard is a video of somebody's worst evening.
 */

/** `+15125550123`, `(512) 555-0123`, `512.555.0123`, and the rest. */
const PHONE = /(\+?1[ .\-])?\(?\d{3}\)?[ .\-]?\d{3}[ .\-]?\d{4}/g;

/** Any run of ten or more digits: account ids, card-shaped things, unformatted numbers. */
const LONG_DIGITS = /\d{10,}/g;

const EMAIL = /[^\s@<>"']+@[^\s@<>"']+\.[^\s@<>"',;)]+/g;

/**
 * A coordinate precise enough to drive to. Four decimal places is about eleven metres, which is
 * a vehicle in a field rather than a town.
 */
const COORDINATE = /-?\d{1,3}\.\d{4,}/g;

/** Anything that looks like a bearer token, an API key or a JWT. */
const SECRET = /\b(ey[A-Za-z0-9_-]{10,}|sb_[a-z]+_[A-Za-z0-9_-]{10,}|sk_[A-Za-z0-9]{10,})\b/g;

/**
 * Path segments that carry a secret or an identifier. `/r/<token>` is the live recovery link.
 *
 * These run against ALL text, not only against things Sentry labelled as a URL. That distinction
 * cost a real leak: the rules used to live in `scrubUrl`, which `scrubDeep` calls only for a key
 * literally named `url`, so a token in an error *message* went out intact. Caught by reading an
 * actual event off the wire — `dispatch failed ... see /r/demo-accepted-token-cccccc` — which the
 * unit tests could not catch, because they were asking whether `scrubUrl` worked and it did. A
 * status token reaches the tracker as prose far more often than as a tagged URL: a thrown
 * message, a fetch breadcrumb, a stack frame filename in a route chunk.
 *
 * The trailing class is the token/slug/uuid alphabet rather than "anything up to the next
 * delimiter". In a URL those are the same thing; in free text they are not, and the loose version
 * would run across the spaces and swallow the rest of the sentence.
 */
const PATH_RULES: [RegExp, string][] = [
  [/\/r\/[A-Za-z0-9_-]+/g, "/r/[token]"],
  [/\/post\/[A-Za-z0-9_-]+/g, "/post/[id]"],
  [/\/trails\/[A-Za-z0-9_-]+/g, "/trails/[slug]"],
  [/\/resources\/[A-Za-z0-9_-]+/g, "/resources/[slug]"],
];

export const REDACTED = "[redacted]";

/**
 * Scrub free text: a message, a stack frame, a breadcrumb.
 *
 * Order matters, and getting it wrong leaves a tail. Path rules go first, so a token is replaced
 * whole while it is still intact: run them after the digit patterns and a token containing a long
 * digit run is already broken into `/r/abc[redacted]def`, which no longer matches. Then emails and
 * keys, because either can contain digits the number patterns would chew through. Then long digit
 * runs, and only then phone numbers: with phones first, a fourteen-digit string had its leading
 * eleven digits matched as a phone and the remaining three left in plain sight — `id
 * [redacted]9876`. A test caught that, which is the entire reason it exists.
 */
export function scrubText(input: string): string {
  let out = input;
  for (const [pattern, replacement] of PATH_RULES) {
    out = out.replace(pattern, replacement);
  }

  return out
    .replace(EMAIL, REDACTED)
    .replace(SECRET, REDACTED)
    .replace(LONG_DIGITS, REDACTED)
    .replace(PHONE, REDACTED)
    .replace(COORDINATE, REDACTED);
}

/**
 * Scrub a URL.
 *
 * The query string is dropped whole rather than filtered. This app puts nothing sensitive in one
 * today, and a denylist of parameter names is a promise about every parameter anybody adds later.
 *
 * That dropping is all this adds over `scrubText` now — the path rules moved down into the text
 * pass, where every string gets them.
 */
export function scrubUrl(input: string): string {
  return scrubText(input.split("#")[0].split("?")[0]);
}

type Loose = Record<string, unknown>;

/**
 * Walk anything Sentry is about to send and scrub every string in it.
 *
 * Recursive and depth-limited: an event carries stack frames, breadcrumbs, tags, contexts and
 * whatever somebody attached to `extra`, and the sensitive value is as likely to be four levels
 * down as at the top.
 */
export function scrubDeep<T>(value: T, depth = 0): T {
  if (depth > 8) return value;

  if (typeof value === "string") return scrubText(value) as unknown as T;

  if (Array.isArray(value)) {
    return value.map((item) => scrubDeep(item, depth + 1)) as unknown as T;
  }

  if (value && typeof value === "object") {
    const source = value as Loose;
    const out: Loose = {};

    for (const [key, item] of Object.entries(source)) {
      // Never send these at all, whatever they contain.
      if (/^(cookie|cookies|authorization|apikey|api_key|token|password|secret)$/i.test(key)) {
        out[key] = REDACTED;
        continue;
      }

      out[key] = key === "url" && typeof item === "string"
        ? scrubUrl(item)
        : scrubDeep(item, depth + 1);
    }

    return out as unknown as T;
  }

  return value;
}
