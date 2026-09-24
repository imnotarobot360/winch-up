import { getTranslations, setRequestLocale } from "next-intl/server";

import { AdSlot } from "@/components/ads/ad-slot";
import {
  IconAlert,
  IconCheck,
  IconChevronRight,
  IconCloud,
  IconHook,
  IconPeople,
  IconWinch,
} from "@/components/ui/icons";
import { Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { GUIDES } from "@/lib/resources";

/**
 * One line icon per guide, as screen 11 of the design reference has it.
 *
 * Mapped to what the guide is actually about rather than to the reference's labels, because the
 * six guides here are the six that exist and have content. The reference lists an Emergency
 * Contacts category; there is no such guide, and adding a seventh row that opened an empty page
 * would break the brief's own rule about resource buttons going nowhere. "Before you go" is the
 * sixth instead, and it is a real page somebody can read.
 */
const ICONS = {
  stuck: IconHook,
  safety: IconAlert,
  gear: IconWinch,
  before: IconCheck,
  etiquette: IconPeople,
  weather: IconCloud,
} as const;

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "resources" });
  // Public and indexable, unlike trails and the feed. This is the one part of the app that is
  // useful to somebody who has never heard of us and is currently standing next to a stuck truck.
  return { title: t("title"), description: t("intro") };
}

export default async function ResourcesPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("resources");

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <h1 className="text-3xl font-bold">{t("title")}</h1>
      <p className="mt-2 text-lg text-ink-soft">{t("intro")}</p>

      {/* Both of these are on the index rather than buried in a guide, because the spec's line
          about not representing volunteers as professionals is not a footnote. */}
      <Callout tone="danger" className="mt-6">
        <p className="font-semibold">{t("emergencyTitle")}</p>
        <p className="mt-1">{t("emergencyBody")}</p>
      </Callout>

      <Callout tone="neutral" className="mt-4">
        <p className="font-semibold">{t("notProsTitle")}</p>
        <p className="mt-1">{t("notProsBody")}</p>
      </Callout>

      {/* The reference's list row: icon, bold title, one line of description, chevron. Rows
          rather than cards -- six cards with five lines of padding each is two screens of
          scrolling for six links. */}
      <ul className="mt-6 divide-y divide-line overflow-hidden rounded-2xl border border-line">
        {GUIDES.map((slug) => {
          const Icon = ICONS[slug];
          return (
            <li key={slug}>
              <Link
                href={`/resources/${slug}`}
                className="flex items-center gap-4 bg-surface px-4 py-4 hover:bg-surface-sunk"
              >
                <span className="flex size-10 shrink-0 items-center justify-center rounded-field bg-surface-sunk text-brand-text">
                  <Icon size={22} />
                </span>

                <span className="min-w-0 flex-1">
                  <span className="block text-base font-bold text-ink">
                    {t(`guides.${slug}.title`)}
                  </span>
                  <span className="mt-0.5 block text-sm text-ink-soft">
                    {t(`guides.${slug}.blurb`)}
                  </span>
                </span>

                {/* aria-hidden: the link text already says where it goes. */}
                <IconChevronRight size={20} className="shrink-0 text-ink-faint" />
              </Link>
            </li>
          );
        })}
      </ul>

      <AdSlot surface="resources" className="mt-6" />
    </main>
  );
}
