import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { SecurityPanel } from "@/components/account/security-panel";
import { Link } from "@/i18n/navigation";
import { enabledSocialProviders } from "@/lib/auth/social-providers";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "security" });
  return { title: t("pageTitle"), robots: { index: false, follow: false } };
}

/**
 * Account & Security.
 *
 * Its own screen rather than another card on /account, for the same reason notifications got
 * one: the ways into an account are what somebody comes looking for when something has gone
 * wrong -- a lost phone, a shared password, a provider they no longer use -- and hunting for
 * them among profile fields is the wrong experience at the wrong moment.
 *
 * `noindex`, like every signed-in screen here.
 *
 * The provider list is read from Supabase at request time rather than from a constant, so a
 * provider turned on or off in the dashboard is reflected without a deploy and no button can
 * appear for something that would fail. Today production has Google and email/password; Apple
 * is in SOCIAL_PROVIDERS but not yet configured, so it correctly does not render.
 */
export default async function SecurityPage({
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
    redirect(`/${locale}/signin?next=${encodeURIComponent(`/${locale}/account/security`)}`);
  }

  const [t, providers] = await Promise.all([
    getTranslations({ locale, namespace: "security" }),
    enabledSocialProviders(),
  ]);

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      <header>
        <Link href="/account" className="text-sm text-ink-soft underline underline-offset-4">
          {t("backToAccount")}
        </Link>
        <h1 className="mt-2 font-display text-3xl">{t("pageTitle")}</h1>
        <p className="mt-1 text-ink-soft">{t("pageBody")}</p>
      </header>

      <SecurityPanel providers={providers} />

      <p className="text-sm text-ink-soft">
        {t("deleteHint")}{" "}
        <Link href="/account" className="underline underline-offset-4">
          {t("deleteLink")}
        </Link>
      </p>
    </main>
  );
}
