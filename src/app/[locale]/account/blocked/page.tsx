import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { BlockedList } from "@/components/account/blocked-list";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "blocked" });
  return { title: t("pageTitle"), robots: { index: false, follow: false } };
}

/**
 * The people you have blocked.
 *
 * Its own screen under /account rather than a panel on the feed: it is a setting about you, it
 * is read rarely, and the feed is where blocking happens -- putting the undo button next to the
 * thing it undoes would be a strange place to look for it weeks later.
 */
export default async function BlockedPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect(`/${locale}/signin?next=${encodeURIComponent(`/${locale}/account/blocked`)}`);
  }

  const t = await getTranslations({ locale, namespace: "blocked" });

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      <header>
        <Link href="/account" className="text-sm text-ink-soft underline underline-offset-4">
          {t("backToAccount")}
        </Link>
        <h1 className="mt-2 font-display text-3xl">{t("pageTitle")}</h1>
        <p className="mt-1 text-ink-soft">{t("pageBody")}</p>
      </header>

      <BlockedList />
    </main>
  );
}
