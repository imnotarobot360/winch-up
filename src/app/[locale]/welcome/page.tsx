import Image from "next/image";
import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { TopoBackdrop } from "@/components/brand/topo";
import { APP_NAME } from "@/config/app";
import { Link } from "@/i18n/navigation";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations("welcome");
  return { title: t("title"), description: t("body") };
}

/**
 * Screen 2 of the design reference: what this is, and two ways in.
 *
 * NOT A GATE. It is a route you can be sent to, never one you are held behind -- there is no
 * "seen onboarding" flag anywhere in this app and there should not be one, because the person
 * this product exists for arrives at /request from a link somebody texted them while they are
 * standing next to a stuck truck. Making them tap through an introduction first would be the
 * single worst thing this redesign could do.
 *
 * ON THE MISSING PHOTOGRAPH
 *
 * The reference fills the top half with a photograph of a Jeep on a rocky trail. There is no such
 * asset in this repository -- public/ holds the logo and the PWA icons, nothing else -- and the
 * brief says to avoid generic stock photography that does not match the rugged off-road identity,
 * and to ask for a missing asset rather than substitute an inaccurate one. So this uses the brand
 * emblem on the contour field instead: honest, on-brand, and a straight swap for a real photo the
 * moment one exists. Drop a 1200x900-ish image at public/brand/onboarding.jpg and replace the
 * <Image> below; nothing else has to change.
 *
 * ONE SCREEN, SO NO DOTS
 *
 * The reference shows pagination dots and a Skip link. The brief qualifies both with "if the
 * onboarding flow contains multiple screens". It does not: there is exactly one thing worth
 * saying before somebody signs up, and three screens of padding to justify a row of dots would
 * be worse for the user than the dots are good for the mockup.
 */
export default async function WelcomePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("welcome");

  return (
    <main className="relative flex min-h-[100dvh] flex-col bg-trail">
      <TopoBackdrop />

      {/* The image half. Sized in viewport units so the copy below is never pushed off a short
          phone -- a 5.4" screen in landscape is still a screen somebody is stuck on. */}
      <div className="relative flex min-h-[38dvh] flex-1 items-center justify-center px-8 pt-[max(1.5rem,env(safe-area-inset-top))]">
        <Image
          src="/brand/logo-lockup.png"
          alt={APP_NAME}
          width={1024}
          height={632}
          sizes="(max-width: 640px) 78vw, 340px"
          className="h-auto w-full max-w-[340px]"
          priority
        />
      </div>

      <div className="relative mx-auto w-full max-w-xl px-6 pb-[max(1.5rem,env(safe-area-inset-bottom))]">
        {/* Three lines, as in the reference. Condensed, uppercase, tight leading -- the one place
            in the app where type is allowed to shout. */}
        <h1 className="font-display text-4xl uppercase leading-[0.95] tracking-tight text-ink sm:text-5xl">
          {t("headline1")}
          <br />
          {t("headline2")}
          <br />
          {t("headline3")}
        </h1>

        <p className="mt-4 text-base leading-relaxed text-ink-soft">{t("body")}</p>

        <div className="mt-7 space-y-3">
          <Link
            href="/signup"
            className="tap-target flex w-full items-center justify-center rounded-field bg-brand px-4 text-center text-lg font-bold text-on-brand"
          >
            {t("getStarted")}
          </Link>
          <Link
            href="/signin"
            className="tap-target flex w-full items-center justify-center rounded-field border-2 border-line px-4 text-center text-lg font-semibold text-ink"
          >
            {t("signIn")}
          </Link>
        </div>

        {/* The way past, for somebody who is here because they need help now rather than because
            they are browsing. It is the whole product; it should never be behind an introduction. */}
        <p className="mt-5 text-center text-sm text-ink-faint">
          {t.rich("needHelpNow", {
            link: (chunks) => (
              <Link href="/request" className="font-semibold text-brand-text underline">
                {chunks}
              </Link>
            ),
          })}
        </p>
      </div>
    </main>
  );
}
