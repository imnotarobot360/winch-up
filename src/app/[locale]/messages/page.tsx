import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { DmInbox } from "@/components/messages/dm-inbox";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dm" });
  return { title: t("pageTitle"), robots: { index: false, follow: false } };
}

/**
 * Direct conversations.
 *
 * Its own section rather than a tab on /community: the feed is public-to-members and moderated, and this
 * is private between two people. Putting them on one screen would invite the mistake of reading a DM as
 * something a moderator can see, which they cannot -- dm_messages has no table access at all.
 *
 * `noindex`, and signed out it redirects rather than rendering an empty shell. Nothing about who is
 * talking to whom should reach a crawler or a stranger.
 */
export default async function MessagesPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect(`/${locale}/signin?next=${encodeURIComponent(`/${locale}/messages`)}`);
  }

  const t = await getTranslations({ locale, namespace: "dm" });

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      <header>
        <Link href="/account" className="text-sm text-ink-soft underline underline-offset-4">
          {t("backToAccount")}
        </Link>
        <h1 className="mt-2 font-display text-3xl">{t("pageTitle")}</h1>
        <p className="mt-1 text-ink-soft">{t("pageBody")}</p>
      </header>

      <DmInbox />
    </main>
  );
}
