import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";
import type { ReactNode } from "react";

import { AdminSignIn } from "@/components/admin/admin-signin";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  robots: { index: false, follow: false },
};

/**
 * The gate.
 *
 * This decides what renders; it is not what enforces anything. Every admin RPC checks
 * `app.is_admin()` for itself, so a forged session or a direct API call gets nowhere.
 */
export default async function AdminLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const t = await getTranslations("admin");
  const supabase = await supabaseServer();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return <AdminSignIn reason="signed_out" />;
  }

  const { data: roles } = await supabase
    .from("user_roles")
    .select("role")
    .eq("user_id", user.id)
    .eq("role", "admin");

  if (!roles || roles.length === 0) {
    return <AdminSignIn reason="not_admin" />;
  }

  const tabs = [
    { href: "/admin", label: t("nav.queue") },
    { href: "/admin/responders", label: t("nav.responders") },
    { href: "/admin/incidents", label: t("nav.incidents") },
    { href: "/admin/intake", label: t("nav.intake") },
    { href: "/admin/settings", label: t("nav.settings") },
    { href: "/admin/audit", label: t("nav.audit") },
  ];

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-6">
      <header className="mb-5">
        <h1 className="text-2xl font-bold">{t("title")}</h1>
        <nav className="mt-3 flex flex-wrap gap-2">
          {tabs.map((tab) => (
            <Link
              key={tab.href}
              href={tab.href}
              className="min-h-12 rounded-field border-2 border-line px-4 py-2 text-base font-semibold"
            >
              {tab.label}
            </Link>
          ))}
        </nav>
      </header>
      {children}
    </div>
  );
}
