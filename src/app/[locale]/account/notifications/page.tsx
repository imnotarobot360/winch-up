import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { NotificationSettings } from "@/components/account/notification-settings";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "notifySettings" });
  return { title: t("pageTitle"), robots: { index: false, follow: false } };
}

/**
 * Notification settings (spec section 8).
 *
 * Its own screen rather than another card on /account. There are eight switches once devices are
 * counted, and they were previously scattered between the profile form and the volunteer
 * section — which meant "stop waking me up" was three places instead of one.
 */
export default async function NotificationSettingsPage({
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
    redirect(`/${locale}/signin?next=${encodeURIComponent(`/${locale}/account/notifications`)}`);
  }

  const t = await getTranslations({ locale, namespace: "notifySettings" });

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      <header>
        <Link href="/account" className="text-sm text-ink-soft underline underline-offset-4">
          {t("backToAccount")}
        </Link>
        <h1 className="mt-2 font-display text-3xl">{t("pageTitle")}</h1>
        <p className="mt-1 text-ink-soft">{t("pageBody")}</p>
      </header>

      <NotificationSettings />
    </main>
  );
}
