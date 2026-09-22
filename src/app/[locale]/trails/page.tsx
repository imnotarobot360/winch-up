import { getTranslations, setRequestLocale } from "next-intl/server";

import { TrailList } from "@/components/trails/trail-list";
import { redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "trails" });
  // noindex, like the feed. A public page asserting that a named place is legal to drive on is
  // a publisher's liability; behind an account, with its source and its date, it is a reference.
  return { title: t("title"), robots: { index: false, follow: false } };
}

export default async function TrailsPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect({ href: "/signin", locale });

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <TrailList />
    </main>
  );
}
