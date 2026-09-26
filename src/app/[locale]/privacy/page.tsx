import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { LEGAL_ENTITY } from "@/config/app";
import { Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "legal" });
  return { title: t("privacy") };
}

export default async function PrivacyPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("legal");

  return (
    <main className="mx-auto w-full max-w-2xl space-y-5 px-4 py-8">
      <Link href="/" className="text-base underline underline-offset-4">
        {t("backHome")}
      </Link>

      <h1 className="text-3xl font-bold">{t("privacy")}</h1>

      {/* Not the PLACEHOLDER banner the other legal pages use: this text is real, and says what
          the code does. It still does not claim anybody qualified has read it. */}
      <Callout tone="neutral">
        <p className="font-bold">{t("unreviewedBanner")}</p>
        <p className="mt-1 text-sm">{t("unreviewedExplainer")}</p>
      </Callout>

      <article className="whitespace-pre-wrap text-base leading-relaxed">
        {t("privacyBody", { entity: LEGAL_ENTITY })}
      </article>
    </main>
  );
}
