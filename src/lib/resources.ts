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
export const GUIDES = ["stuck", "safety", "gear", "before", "etiquette", "weather"] as const;

export type GuideSlug = (typeof GUIDES)[number];

export type GuideSection = { heading: string; items: string[] };

export function isGuideSlug(value: string): value is GuideSlug {
  return (GUIDES as readonly string[]).includes(value);
}
