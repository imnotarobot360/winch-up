import { getTranslations, setRequestLocale } from "next-intl/server";

import { AdSlot } from "@/components/ads/ad-slot";
import { Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { GUIDES } from "@/lib/resources";

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

      <ul className="mt-6 space-y-3">
        {GUIDES.map((slug) => (
          <li key={slug}>
            <Link
              href={`/resources/${slug}`}
              className="block rounded-2xl border border-line bg-surface p-5 hover:bg-surface-sunk"
            >
              <p className="text-lg font-semibold">{t(`guides.${slug}.title`)}</p>
              <p className="mt-1 text-base text-ink-soft">{t(`guides.${slug}.blurb`)}</p>
            </Link>
          </li>
        ))}
      </ul>

      <AdSlot surface="resources" className="mt-6" />
    </main>
  );
}
