import { setRequestLocale } from "next-intl/server";

import { TrailDetail } from "@/components/trails/trail-detail";
import { redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export const metadata = {
  robots: { index: false, follow: false },
};

export default async function TrailPage({
  params,
}: {
  params: Promise<{ locale: string; slug: string }>;
}) {
  const { locale, slug } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect({ href: "/signin", locale });

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <TrailDetail slug={slug} />
    </main>
  );
}
