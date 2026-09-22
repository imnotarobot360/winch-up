import Image from "next/image";
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
        * The launch panel from the brand board. The lockup is real artwork with its own alpha,
        * so it sits directly on the Trail Green field.
        *
        * The motto is part of the artwork and therefore English-only. The translated app.motto
        * string is deliberately not repeated here -- an English reader would see it twice -- so
        * a Spanish lockup is the thing that closes that gap.
        */}
      <header className="-mx-4 -mt-8 mb-8 bg-trail px-4 pt-10 pb-8">
        <h1 className="m-0">
          <Image
            src="/brand/logo-lockup.png"
            alt={APP_NAME}
            width={1024}
            height={632}
            sizes="(max-width: 640px) 90vw, 420px"
            className="h-auto w-full max-w-[420px]"
            priority
          />
        </h1>
        <p className="mt-2 text-lg text-ink">{tApp("tagline")}</p>
      </header>

      {/* The only thing on this page that matters to someone who is actually stuck. */}
      <Link
        href="/request"
        className="tap-target mt-8 flex w-full items-center justify-center rounded-field text-center bg-brand px-6 text-xl font-bold text-on-brand"
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
          className="tap-target flex w-full items-center justify-center rounded-field text-center border-2 border-line px-4 text-lg font-semibold"
        >
          {t("volunteerCta")}
        </Link>
      </Card>

      <Card className="mt-4 space-y-3">
        <h2 className="text-xl font-semibold">{t("boardTitle")}</h2>
        <p className="text-base text-ink-soft">{t("boardBody")}</p>
        <Link
          href="/board"
          className="tap-target flex w-full items-center justify-center rounded-field text-center border-2 border-line px-4 text-lg font-semibold"
        >
          {t("boardCta")}
        </Link>
      </Card>

      {/* Behind an account, so this is a door rather than the directory itself. */}
      <Card className="mt-4 space-y-3">
        <h2 className="text-xl font-semibold">{t("trailsTitle")}</h2>
        <p className="text-base text-ink-soft">{t("trailsBody")}</p>
        <Link
          href="/trails"
          className="tap-target flex w-full items-center justify-center rounded-field text-center border-2 border-line px-4 text-lg font-semibold"
        >
          {t("trailsLink")}
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
