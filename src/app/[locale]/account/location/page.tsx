import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { LocationSettings } from "@/components/account/location-settings";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "locationSettings" });
  return { title: t("pageTitle"), robots: { index: false, follow: false } };
}

/**
 * Where a member says they are (spec section 11).
 *
 * Its own screen rather than another card on /account, for the same reason the notification
 * switches got one: /account is already a long page, and a field whose whole job is to be
 * findable does not belong below the fold of something else.
 */
export default async function LocationSettingsPage({
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
    redirect(`/${locale}/signin?next=${encodeURIComponent(`/${locale}/account/location`)}`);
  }

  const t = await getTranslations({ locale, namespace: "locationSettings" });

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      <header>
        <Link href="/account" className="text-sm text-ink-soft underline underline-offset-4">
          {t("backToAccount")}
        </Link>
        <h1 className="mt-2 font-display text-3xl">{t("pageTitle")}</h1>
        <p className="mt-1 text-ink-soft">{t("pageBody")}</p>
      </header>

      <LocationSettings />
    </main>
  );
}
