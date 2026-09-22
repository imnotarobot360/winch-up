import { getTranslations, setRequestLocale } from "next-intl/server";

import { VehiclesManager } from "@/components/vehicles/vehicles-manager";
import { Link, redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "vehicles" });
  return { title: t("title") };
}

export default async function VehiclesPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Checked on the server so the page never renders for a signed-out visitor. This returns a 200
  // with a client navigation rather than a 307, because the head has already flushed by the time
  // it fires -- test it in a browser, not with curl.
  if (!user) redirect({ href: "/signin", locale });

  const t = await getTranslations("vehicles");

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <h1 className="text-3xl font-bold">{t("title")}</h1>
      <p className="mt-2 text-lg text-ink-soft">{t("body")}</p>

      <div className="mt-6">
        <VehiclesManager userId={user!.id} />
      </div>

      <Link
        href="/account"
        className="mt-8 inline-block text-base text-brand-text underline underline-offset-4"
      >
        {t("backToAccount")}
      </Link>
    </main>
  );
}
