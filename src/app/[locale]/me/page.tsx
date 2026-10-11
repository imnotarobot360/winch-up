import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { MeDashboard } from "@/components/responder/me-dashboard";
import { signAvatar } from "@/lib/avatar-photos";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "me" });
  return { title: t("pageTitle"), robots: { index: false, follow: false } };
}

export default async function MePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  let avatarUrl: string | null = null;
  if (user) {
    const { data: profile } = await supabase
      .from("profiles")
      .select("avatar_path")
      .eq("user_id", user.id)
      .maybeSingle();
    avatarUrl = await signAvatar(profile?.avatar_path);
  }

  return <MeDashboard initialAvatarUrl={avatarUrl} />;
}
