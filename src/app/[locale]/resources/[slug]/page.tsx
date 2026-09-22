import { notFound } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { Callout, Card } from "@/components/ui/primitives";
import { routing } from "@/i18n/routing";
import { Link } from "@/i18n/navigation";
import { GUIDES, isGuideSlug, type GuideSection } from "@/lib/resources";

/**
 * The guide list is fixed at build time, so anything else is a 404 from the router rather than
 * from this component.
 *
 * That distinction is the difference between a real 404 and a 200 that looks like one. With
 * dynamic params allowed, an unknown slug rendered, flushed the head, and only then called
 * notFound() -- the status was already committed, so /resources/not-a-guide answered 200 with
 * not-found content on it. Harmless in a browser, wrong for a section that is deliberately
 * indexable. (The same flush is why a redirect looks like a 200 to curl; see account/page.tsx.)
 */
export const dynamicParams = false;

export function generateStaticParams() {
  return routing.locales.flatMap((locale) => GUIDES.map((slug) => ({ locale, slug })));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string; slug: string }>;
}) {
  const { locale, slug } = await params;

  // An unknown slug still answers 200, because next-intl rewrites the request and the head has
  // flushed by the time notFound() runs -- the same reason a redirect here looks like a 200 to
  // curl. A browser lands on the not-found page correctly; a crawler would file a soft 404. So
  // say noindex explicitly rather than pretend the status is right.
  if (!isGuideSlug(slug)) return { robots: { index: false, follow: false } };

  const t = await getTranslations({ locale, namespace: "resources" });
  return {
    title: t(`guides.${slug}.title`),
    description: t(`guides.${slug}.blurb`),
  };
}

export default async function GuidePage({
  params,
}: {
  params: Promise<{ locale: string; slug: string }>;
}) {
  const { locale, slug } = await params;
  setRequestLocale(locale);

  if (!isGuideSlug(slug)) notFound();

  const t = await getTranslations("resources");

  // Arrays come back through `raw`. The shape is held to English by check-messages.mjs, which
  // walks arrays by index -- a Spanish section with fewer items fails the build.
  const sections = t.raw(`guides.${slug}.sections`) as GuideSection[];

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <Link href="/resources" className="text-base underline underline-offset-4">
        {t("backToResources")}
      </Link>

      <h1 className="mt-4 text-3xl font-bold">{t(`guides.${slug}.title`)}</h1>
      <p className="mt-2 text-lg text-ink-soft">{t(`guides.${slug}.lede`)}</p>

      {/* Repeated on every guide, not only the index. People arrive on these pages from a search
          result or a forwarded link, and a safety page that reads as professional advice is the
          exact thing the spec tells us not to publish. */}
      <Callout tone="neutral" className="mt-6">
        <p className="font-semibold">{t("notProsTitle")}</p>
        <p className="mt-1 text-sm">{t("notProsBody")}</p>
      </Callout>

      <div className="mt-6 space-y-4">
        {sections.map((section) => (
          <Card key={section.heading} className="space-y-2">
            <h2 className="text-xl font-semibold">{section.heading}</h2>
            <ul className="list-outside list-disc space-y-2 pl-5 text-base leading-relaxed text-ink-soft">
              {section.items.map((item) => (
                <li key={item}>{item}</li>
              ))}
            </ul>
          </Card>
        ))}
      </div>

      {slug === "weather" ? (
        <p className="mt-4 text-sm text-ink-faint">{t("externalNote")}</p>
      ) : null}

      <Callout tone="danger" className="mt-6">
        <p className="font-semibold">{t("emergencyTitle")}</p>
        <p className="mt-1">{t("emergencyBody")}</p>
      </Callout>

      <nav className="mt-8 space-y-2">
        {GUIDES.filter((other) => other !== slug).map((other) => (
          <Link
            key={other}
            href={`/resources/${other}`}
            className="block text-base underline underline-offset-4"
          >
            {t(`guides.${other}.title`)}
          </Link>
        ))}
      </nav>
    </main>
  );
}
