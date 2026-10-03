import { getTranslations, setRequestLocale } from "next-intl/server";

import { AdminContent } from "@/components/admin/admin-content";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "adminContent" });
  return { title: t("title"), robots: { index: false, follow: false } };
}

/**
 * Content & Marketing (spec sections 1, 14 and 16).
 *
 * INSIDE THE EXISTING ADMIN, which the owner's spec requires in as many words: "do not create a
 * separate application". It also happens to be the only arrangement that is safe — the admin layout
 * holds the gate, the MFA requirement and the audit trail, and every RPC behind this screen checks
 * app.is_admin() for itself, so what renders here is presentation rather than permission.
 */
export default async function AdminContentPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const t = await getTranslations({ locale, namespace: "adminContent" });

  return (
    <section className="space-y-4">
      <header>
        <h2 className="text-xl font-semibold text-ink">{t("title")}</h2>
        <p className="mt-1 text-ink-soft">{t("subtitle")}</p>
      </header>

      <AdminContent />
    </section>
  );
}
