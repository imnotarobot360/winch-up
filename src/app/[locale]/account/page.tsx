import { getTranslations, setRequestLocale } from "next-intl/server";

import { AccountForm } from "@/components/account/account-form";
import { redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "account" });
  return { title: t("title") };
}

export default async function AccountPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Checked on the server: a client-side redirect would render the page first.
  if (!user) redirect({ href: "/signin", locale });

  const t = await getTranslations("account");

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-8">
      <h1 className="text-3xl font-bold">{t("title")}</h1>
      <p className="mt-2 text-lg text-ink-soft">{t("body")}</p>
      <div className="mt-6">
        <AccountForm email={user!.email ?? user!.phone ?? ""} />
      </div>
    </main>
  );
}
