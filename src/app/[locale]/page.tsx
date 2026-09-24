import Image from "next/image";
import { getTranslations, setRequestLocale } from "next-intl/server";

import type { BoardRow } from "@/components/board/board-list";
import { HomeMap } from "@/components/home/home-map";
import { Callout, Card } from "@/components/ui/primitives";
import { APP_NAME } from "@/config/app";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

/**
 * Two different home pages, decided by whether anybody is signed in.
 *
 * Signed in, this is screen 4 of the design reference: the map, with the SOS card over it. That
 * is the right home for somebody who already belongs here -- they do not need to be told what the
 * app is every time they open it.
 *
 * Signed out, it stays the landing page. It is the page search engines index and the page a
 * stranger reaches from a link in a Facebook group, and replacing it with a map they cannot use
 * would trade the product's whole front door for a closer match to a mockup.
 *
 * The map is not rendered for signed-out visitors at all, rather than rendered empty: it costs a
 * Mapbox tile load and a 400KB library to show a stranger a map of nothing.
 */
export default async function HomePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (user) {
    // The same blurred rows the public board serves. A member's own home map is not a reason to
    // widen what a recovery's location looks like to somebody who is not on it.
    const { data } = await supabase.rpc("board_requests", { p_limit: 100 });
    return <HomeMap rows={(data as BoardRow[] | null) ?? []} />;
  }

  return <LandingPage />;
}

async function LandingPage() {

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

      <Card className="mt-4 space-y-3">
        <h2 className="text-xl font-semibold">{t("resourcesTitle")}</h2>
        <p className="text-base text-ink-soft">{t("resourcesBody")}</p>
        <Link
          href="/resources"
          className="tap-target flex w-full items-center justify-center rounded-field text-center border-2 border-line px-4 text-lg font-semibold"
        >
          {t("resourcesLink")}
        </Link>
      </Card>

      <nav className="mt-10 flex flex-wrap gap-4 text-base text-ink-soft">
        <Link href="/terms" className="underline underline-offset-4">
          {tLegal("terms")}
        </Link>
        <Link href="/waiver" className="underline underline-offset-4">
          {tLegal("waiver")}
        </Link>
        <Link href="/business" className="underline underline-offset-4">
          {t("advertiseLink")}
        </Link>
        <Link href="/privacy" className="underline underline-offset-4">
          {tLegal("privacy")}
        </Link>
      </nav>
    </main>
  );
}
