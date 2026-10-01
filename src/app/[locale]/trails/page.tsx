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

export default async function TrailsPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams: Promise<{ saved?: string }>;
}) {
  const { locale } = await params;
  // "Saved trails" on the account menu is this page with its saved filter already on, rather
  // than a second page listing the same rows. One screen, one set of filters, one thing to keep
  // working -- and the chip stays visible, so it is obvious why the list is short.
  const { saved } = await searchParams;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect({ href: "/signin", locale });

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <TrailList savedOnly={saved === "1"} />
    </main>
  );
}
