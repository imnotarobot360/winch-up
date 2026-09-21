import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { RequestWizard } from "@/components/request/request-wizard";
import { redirect } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "request" });
  return { title: t("pageTitle") };
}

export default async function RequestPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  // A request belongs to an account, so the wizard is not reachable without one. Checked on the
  // server: a client-side redirect would render eight steps of form first and only then refuse
  // the submit, which is a worse thing to do to someone who is stuck.
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect({ href: "/signin?next=/request", locale });

  return <RequestWizard />;
}
