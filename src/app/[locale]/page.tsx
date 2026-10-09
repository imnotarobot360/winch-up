import { cookies } from "next/headers";
import Image from "next/image";
import { LifeBuoy, MapPinned, HandHelping, Mountain, BookOpen } from "lucide-react";
import { TopoBackdrop } from "@/components/brand/topo";
import { getTranslations, setRequestLocale } from "next-intl/server";

import type { BoardRow } from "@/components/board/board-list";
import { HomeMap } from "@/components/home/home-map";
import { getMembershipAgreement } from "@/app/actions/membership";
import { MembershipBanner } from "@/components/membership/membership-banner";
import { RigPhotoBanner } from "@/components/vehicles/rig-photo-banner";
import { Callout, Card } from "@/components/ui/primitives";
import { APP_NAME } from "@/config/app";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";
import { redirect } from "@/i18n/navigation";
import { SEEN_WELCOME } from "@/middleware";

/**
 * Two different home pages, decided by whether anybody is signed in.
 *
 * Signed in, this is screen 4 of the design reference: the map, with the SOS card over it. That
 * is the right home for somebody who already belongs here -- they do not need to be told what the
 * app is every time they open it.
 *
 * Signed out and arriving for the FIRST time, it is screen 2 of the reference: the onboarding
 * screen at /welcome. That screen was built and deployed and then nothing ever linked to it, so
 * the first thing a new visitor actually saw was the landing page below -- which is not in the
 * reference at all.
 *
 * Signed out and returning, it stays the landing page. It is the page search engines index and
 * the page a stranger reaches from a link in a Facebook group, and making every visit start at a
 * full-bleed splash would trade the product's front door for a closer match to a mockup. Once is
 * onboarding; twice is an obstacle.
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

  if (!user) {
    // First visit only. The cookie is set by the middleware on the response that serves
    // /welcome, so it lands whether they were redirected there or typed the URL, and works with
    // JavaScript off.
    const seenWelcome = (await cookies()).has(SEEN_WELCOME);
    if (!seenWelcome) redirect({ href: "/welcome", locale });
  }

  if (user) {
    // The same blurred rows the public board serves. A member's own home map is not a reason to
    // widen what a recovery's location looks like to somebody who is not on it.
    const { data } = await supabase.rpc("board_requests", { p_limit: 100 });

    // Decided here rather than inside the banners so that a member who needs neither causes
    // no element to exist at all -- see the note on MembershipBanner.
    const [membership, rig] = await Promise.all([
      getMembershipAgreement(),
      supabase.rpc("my_rig_photo_status"),
    ]);

    const rigStatus = rig.data as
      | { ok: boolean; vehicle_count: number; needs_photo: boolean }
      | null;

    /**
     * ONE banner at a time, most important first.
     *
     * Both of these are "your account is not finished" nags sitting over the map somebody
     * opens when their truck is in a ditch. Stacked, they would push the SOS card down and
     * read as a checklist; shown one at a time, each gets dealt with and the next appears.
     * The agreement outranks the photo because it is the one with legal weight.
     */
    const banner = membership?.state?.needs_signature ? (
      <MembershipBanner />
    ) : rigStatus?.ok && rigStatus.needs_photo ? (
      <RigPhotoBanner hasVehicle={rigStatus.vehicle_count > 0} />
    ) : undefined;

    return <HomeMap rows={(data as BoardRow[] | null) ?? []} banner={banner} />;
  }

  return <LandingPage />;
}

async function LandingPage() {

  const t = await getTranslations("home");
  const tApp = await getTranslations("app");
  const tLegal = await getTranslations("legal");

  return (
    <main className="winch-screen max-w-5xl">
      {/*
        * The launch panel from the brand board. The lockup is real artwork with its own alpha,
        * so it sits directly on the Trail Green field.
        *
        * The motto is part of the artwork and therefore English-only. The translated app.motto
        * string is deliberately not repeated here -- an English reader would see it twice -- so
        * a Spanish lockup is the thing that closes that gap.
        */}
      <header className="winch-panel relative mb-6 overflow-hidden border border-line bg-trail p-6 sm:p-10">
        <TopoBackdrop />
        <div className="relative sm:flex sm:items-center sm:gap-10">
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
        <p className="mt-4 max-w-sm text-xl font-semibold text-ink sm:text-2xl">{tApp("tagline")}</p>
        </div>
      </header>

      {/* The only thing on this page that matters to someone who is actually stuck. */}
      <Link
        href="/request"
        className="winch-primary-action w-full text-xl"
      >
        <LifeBuoy size={26} aria-hidden="true" />
        {t("stuckCta")}
      </Link>

      <Callout tone="danger" className="mt-4">
        {t("emergencyNote")}
      </Callout>

      <Card className="mt-6 space-y-3">
        <h2 className="text-xl font-semibold">{t("howTitle")}</h2>
        <ol className="list-decimal space-y-1 pl-5 text-base text-ink-soft">
          <li>{t("how1")}</li>
          <li>{t("how2")}</li>
          <li>{t("how3")}</li>
        </ol>
      </Card>

      <div className="mt-4 grid gap-4 sm:grid-cols-2">
      <Card className="flex h-full flex-col gap-3">
        <HandHelping size={26} className="text-brand-text" aria-hidden="true" />
        <h2 className="text-xl font-semibold">{t("volunteerTitle")}</h2>
        <p className="text-base text-ink-soft">{t("volunteerSoon")}</p>
        <Link
          href="/join"
          className="winch-secondary-action mt-auto"
        >
          {t("volunteerCta")}
        </Link>
      </Card>

      <Card className="flex h-full flex-col gap-3">
        <MapPinned size={26} className="text-brand-text" aria-hidden="true" />
        <h2 className="text-xl font-semibold">{t("boardTitle")}</h2>
        <p className="text-base text-ink-soft">{t("boardBody")}</p>
        <Link
          href="/board"
          className="winch-secondary-action mt-auto"
        >
          {t("boardCta")}
        </Link>
      </Card>

      {/* Behind an account, so this is a door rather than the directory itself. */}
      <Card className="flex h-full flex-col gap-3">
        <Mountain size={26} className="text-brand-text" aria-hidden="true" />
        <h2 className="text-xl font-semibold">{t("trailsTitle")}</h2>
        <p className="text-base text-ink-soft">{t("trailsBody")}</p>
        <Link
          href="/trails"
          className="winch-secondary-action mt-auto"
        >
          {t("trailsLink")}
        </Link>
      </Card>

      <Card className="flex h-full flex-col gap-3">
        <BookOpen size={26} className="text-brand-text" aria-hidden="true" />
        <h2 className="text-xl font-semibold">{t("resourcesTitle")}</h2>
        <p className="text-base text-ink-soft">{t("resourcesBody")}</p>
        <Link
          href="/resources"
          className="winch-secondary-action mt-auto"
        >
          {t("resourcesLink")}
        </Link>
      </Card>

      </div>

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
