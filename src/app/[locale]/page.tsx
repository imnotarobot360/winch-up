import { getTranslations, setRequestLocale } from "next-intl/server";

import { Callout, Card } from "@/components/ui/primitives";
import { APP_NAME } from "@/config/app";
import { Link } from "@/i18n/navigation";

export default async function HomePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const t = await getTranslations("home");
  const tApp = await getTranslations("app");
  const tLegal = await getTranslations("legal");

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <h1 className="text-3xl font-bold">{APP_NAME}</h1>
      <p className="mt-2 text-lg text-ink-soft">{tApp("tagline")}</p>

      {/* The only thing on this page that matters to someone who is actually stuck. */}
      <Link
        href="/request"
        className="tap-target mt-8 flex w-full items-center justify-center rounded-field bg-brand px-6 text-xl font-bold text-white"
      >
        {t("stuckCta")}
      </Link>

      <Callout tone="danger" className="mt-4">
        {t("emergencyNote")}
      </Callout>

      <Card className="mt-8 space-y-2">
        <h2 className="text-xl font-semibold">{t("howTitle")}</h2>
        <ol className="list-decimal space-y-1 pl-5 text-base text-ink-soft">
          <li>{t("how1")}</li>
          <li>{t("how2")}</li>
          <li>{t("how3")}</li>
        </ol>
      </Card>

      <Card className="mt-4 space-y-2">
        <h2 className="text-xl font-semibold">{t("volunteerTitle")}</h2>
        <p className="text-base text-ink-soft">{t("volunteerSoon")}</p>
      </Card>

      <nav className="mt-10 flex flex-wrap gap-4 text-base text-ink-soft">
        <Link href="/terms" className="underline underline-offset-4">
          {tLegal("terms")}
        </Link>
        <Link href="/waiver" className="underline underline-offset-4">
          {tLegal("waiver")}
        </Link>
        <Link href="/privacy" className="underline underline-offset-4">
          {tLegal("privacy")}
        </Link>
      </nav>
    </main>
  );
}
