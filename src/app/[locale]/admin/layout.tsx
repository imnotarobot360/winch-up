import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";
import type { ReactNode } from "react";

import { AdminNeedsMfa } from "@/components/admin/admin-needs-mfa";
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

  /**
   * Being an admin is one of TWO questions, and this gate used to ask only the first.
   *
   * With `security.require_admin_mfa` on and a session still at aal1, a real admin passed the role
   * check above, got the whole console, and then watched every screen render an empty list -- each
   * RPC behind them raising `mfa_required`, which nothing in the app displayed. Locked and broken
   * are indistinguishable from the outside, and only one of them deserves a support message.
   *
   * `admin_session_state()` is the one function in this surface that REPORTS a refusal instead of
   * raising, which is what makes it callable here. It is still not what enforces anything: every
   * admin RPC checks for itself, so this decides what renders and nothing more.
   */
  const { data: session } = await supabase.rpc("admin_session_state");
  const state = session as { ok?: boolean; reason?: string } | null;

  if (state && !state.ok && state.reason === "mfa_required") {
    return (
      <div className="mx-auto w-full max-w-3xl px-4 py-6">
        <AdminNeedsMfa />
      </div>
    );
  }

  const tabs = [
    { href: "/admin", label: t("nav.queue") },
    { href: "/admin/responders", label: t("nav.responders") },
    { href: "/admin/incidents", label: t("nav.incidents") },
    { href: "/admin/intake", label: t("nav.intake") },
    { href: "/admin/trails", label: t("nav.trails") },
    { href: "/admin/ads", label: t("nav.ads") },
    { href: "/admin/content", label: t("nav.content") },
    { href: "/admin/membership", label: t("nav.membership") },
    { href: "/admin/settings", label: t("nav.settings") },
    { href: "/admin/security", label: t("nav.security") },
    // Beside system rather than settings: this is "what happened", like the health screen, not
    // "what is configured". The settings it shows are read-only context for the numbers.
    { href: "/admin/alerts", label: t("nav.alerts") },
    { href: "/admin/system", label: t("nav.system") },
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
