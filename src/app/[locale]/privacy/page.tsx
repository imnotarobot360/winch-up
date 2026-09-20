import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

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

      <Callout tone="danger">
        <p className="font-bold">{t("reviewBanner")}</p>
        <p className="mt-1 text-sm">{t("reviewExplainer")}</p>
      </Callout>

      <article className="whitespace-pre-wrap text-base leading-relaxed">
        {t("privacyBody")}
      </article>
    </main>
  );
}
