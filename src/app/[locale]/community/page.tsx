import { getTranslations, setRequestLocale } from "next-intl/server";

import { CommunityFeed } from "@/components/community/community-feed";
import { redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "community" });
  // Members-only, so it stays out of search results. /board is the public surface and it is
  // deliberately thin: no names, no phones, a blurred pin.
  return { title: t("title"), robots: { index: false, follow: false } };
}

export default async function CommunityPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // See the note in account/page.tsx: this is a client navigation, not a 307, because the head
  // has already flushed. Verify it in a browser, not with curl.
  if (!user) redirect({ href: "/signin", locale });

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <CommunityFeed />
    </main>
  );
}
