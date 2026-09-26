import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { LEGAL_ENTITY } from "@/config/app";
import { LegalDocument } from "@/components/legal/legal-document";

// The waiver text is versioned in the database. An admin who publishes a new version needs it
// live now, not at the next deploy, so this page is never prerendered.
export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "legal" });
  return { title: t("terms") };
}

export default async function TermsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("legal");

  return (
    <LegalDocument slug="rules" locale={locale} title={t("terms")}>
      {/*
        The SMS terms are rendered here rather than folded into the `rules` waiver, and that is
        deliberate. A waiver row is immutable and every acceptance points at a version: adding a
        section would mean publishing a new version, which makes every existing acceptance point
        at superseded text and asks people to re-accept. These are carrier-required disclosure,
        not something anybody agrees to, so they do not belong in the accepted document.

        A2P 10DLC review requires this page to carry an SMS section, a "message and data rates may
        apply" line, and the brand name. All three are in the copy.
      */}
      <section id="sms" className="space-y-3 border-t border-line pt-6" aria-labelledby="sms-terms-heading">
        <h2 id="sms-terms-heading" className="text-2xl font-bold">
          {t("smsTermsTitle")}
        </h2>
        <article className="whitespace-pre-wrap text-base leading-relaxed">
          {t("smsTermsBody", { entity: LEGAL_ENTITY })}
        </article>
      </section>
    </LegalDocument>
  );
}
