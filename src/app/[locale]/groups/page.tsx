import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { GroupsList } from "@/components/groups/groups-list";
import { Link, redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "groups" });
  // Members-only, like the feed and the member directory: a list of local crews with their
  // regions is not something to hand to a search engine.
  return { title: t("title"), robots: { index: false, follow: false } };
}

/**
 * Groups (spec section 8's deferred half).
 *
 * The tables and RPCs have existed since phase 12; this is the first screen that reaches them.
 */
export default async function GroupsPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // A client navigation rather than a 307 -- see the note in account/page.tsx. Check it in a
  // browser, not with curl.
  if (!user) redirect({ href: "/signin", locale });

  const t = await getTranslations({ locale, namespace: "groups" });

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      <header>
        <Link href="/community" className="text-sm text-ink-soft underline underline-offset-4">
          {t("backToCommunity")}
        </Link>
        <h1 className="mt-2 text-3xl font-bold text-ink">{t("title")}</h1>
        <p className="mt-1 text-base text-ink-soft">{t("subtitle")}</p>
      </header>

      <GroupsList />
    </main>
  );
}
