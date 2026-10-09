import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { DmThread } from "@/components/messages/dm-thread";
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
  // The OTHER member's name is deliberately not in the title. A browser tab, a history entry and a
  // shared screenshot all carry it, and who somebody is talking to is the private part of a private
  // conversation.
  return { title: t("pageTitle"), robots: { index: false, follow: false } };
}

/**
 * One conversation.
 *
 * The thread id is in the URL and is NOT a capability: dm_thread() derives participation from
 * auth.uid() and answers not_found for a thread that is not yours -- the same not_found it gives for
 * one that does not exist, so a forwarded link reveals nothing, not even whether it was real. That is
 * the opposite of /r/[token], where the token IS the key and is shareable by design.
 */
export default async function MessageThreadPage({
  params,
}: {
  params: Promise<{ locale: string; threadId: string }>;
}) {
  const { locale, threadId } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect(`/${locale}/signin?next=${encodeURIComponent(`/${locale}/messages/${threadId}`)}`);
  }

  const t = await getTranslations({ locale, namespace: "dm" });

  return (
    <main className="winch-screen mx-auto flex max-w-3xl flex-col gap-4">
      <Link href="/messages" className="inline-flex min-h-11 items-center text-sm text-ink-soft underline underline-offset-4">
        {t("backToInbox")}
      </Link>

      <DmThread threadId={threadId} />
    </main>
  );
}
