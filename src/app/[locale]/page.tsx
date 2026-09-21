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
      {/*
        * The launch panel from the brand board: Trail Green field, wordmark in the display face,
        * motto in Recovery Orange. This is the one place orange carries text, because on Trail
        * Green it is 5.19:1 -- on white the same orange would be 2.87:1 and illegible in sun.
        */}
      <header className="-mx-4 -mt-8 mb-8 bg-trail px-4 pt-10 pb-8">
        <h1 className="display text-5xl text-white">{APP_NAME}</h1>
        <p className="display mt-1 text-2xl text-brand">{tApp("motto")}</p>
        <p className="mt-4 text-lg text-white">{tApp("tagline")}</p>
      </header>

      {/* The only thing on this page that matters to someone who is actually stuck. */}
      <Link
        href="/request"
        className="tap-target mt-8 flex w-full items-center justify-center rounded-field bg-brand px-6 text-xl font-bold text-on-brand"
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

      <Card className="mt-4 space-y-3">
        <h2 className="text-xl font-semibold">{t("volunteerTitle")}</h2>
        <p className="text-base text-ink-soft">{t("volunteerSoon")}</p>
        <Link
          href="/join"
          className="tap-target flex w-full items-center justify-center rounded-field border-2 border-line px-4 text-lg font-semibold"
        >
          {t("volunteerCta")}
        </Link>
      </Card>

      <Card className="mt-4 space-y-3">
        <h2 className="text-xl font-semibold">{t("boardTitle")}</h2>
        <p className="text-base text-ink-soft">{t("boardBody")}</p>
        <Link
          href="/board"
          className="tap-target flex w-full items-center justify-center rounded-field border-2 border-line px-4 text-lg font-semibold"
        >
          {t("boardCta")}
        </Link>
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
