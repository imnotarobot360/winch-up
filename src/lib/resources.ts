/**
 * The recovery resources section.
 *
 * Content lives in messages/{en,es}.json rather than in the database, which is a deliberate
 * trade. It means editing needs a deploy; it also means the text goes through review like code,
 * and that `scripts/check-messages.mjs` holds English and Spanish to the same list of items --
 * it walks arrays by index, so a Spanish checklist missing two lines fails the build rather than
 * quietly dropping the two about what never to pull from.
 *
 * Move it to a table if the owner wants to edit without deploying. Version it like the waiver if
 * that happens: safety text that can change silently is worse than safety text that cannot.
 */
// "emergency" is LAST in the list and first in importance, which is not a contradiction: the
// index is read top to bottom by somebody browsing, and reached by somebody in trouble through
// the 911 panel and the status page, not by scrolling. It is also one of the three slugs
// app.ad_slot_allowed() refuses to put an advert beside -- see 20261001000100.
export const GUIDES = [
  "stuck",
  "safety",
  "gear",
  "before",
  "etiquette",
  "weather",
  "emergency",
] as const;

export type GuideSlug = (typeof GUIDES)[number];

export type GuideSection = { heading: string; items: string[] };

export function isGuideSlug(value: string): value is GuideSlug {
  return (GUIDES as readonly string[]).includes(value);
}
