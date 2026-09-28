import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { getMembershipAgreement } from "@/app/actions/membership";
import { AgreementForm } from "@/components/membership/agreement-form";
import { Button, Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";

// The agreement is versioned in the database, and an admin who publishes a new version needs it
// live now rather than at the next deploy -- same reasoning as /waiver.
export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "membership" });
  return { title: t("title") };
}

/**
 * The membership agreement: read it, sign it, or come back and read what you signed.
 *
 * One page for all three states, because they are the same document seen from different points
 * in time and splitting them would mean three places to keep the text consistent.
 *
 * A member who signed an older version sees THAT version, not the current one. `signed_document`
 * is a separate field from `agreement` for exactly this reason -- showing somebody the newest
 * text over their older signature would misrepresent what they agreed to.
 */
export default async function AgreementPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("membership");
  const tLegal = await getTranslations("legal");

  const data = await getMembershipAgreement();
  const signed = data?.signed_document ?? null;
  const current = data?.agreement ?? null;

  const bodyOf = (doc: { body_en: string; body_es: string }) =>
    locale === "es" ? doc.body_es : doc.body_en;

  return (
    <main className="mx-auto w-full max-w-2xl space-y-5 px-4 py-8">
      <Link href="/" className="text-base underline underline-offset-4">
        {tLegal("backHome")}
      </Link>

      <h1 className="text-3xl font-bold">{t("title")}</h1>
      <p className="text-base text-ink-soft">{t("intro")}</p>

      {/* The same banner every other legal document in this app carries, and for the same
          reason: none of this text has been through an attorney yet. It is shown to members
          rather than kept in a comment, because the person signing is entitled to know. */}
      <Callout tone="danger">
        <p className="font-bold">{tLegal("reviewBanner")}</p>
        <p className="mt-1 text-sm">{tLegal("reviewExplainer")}</p>
      </Callout>

      {signed ? (
        <section className="space-y-4">
          <Callout tone="good" className="space-y-1">
            <h2 className="text-lg font-bold">{t("signedHeading")}</h2>
            <p>
              {t("signedOn", {
                date: new Date(signed.signed_at).toLocaleDateString(locale, {
                  year: "numeric",
                  month: "long",
                  day: "numeric",
                }),
                name: signed.legal_name,
              })}
            </p>
            <p className="text-sm">{t("signedVersion", { version: signed.version })}</p>
            {current && current.version !== signed.version ? (
              <p className="text-sm">{t("signedNewer")}</p>
            ) : null}
            <p className="font-mono text-xs break-all">
              {t("documentRef", { hash: signed.body_hash })}
            </p>
          </Callout>

          <article className="max-h-[32rem] overflow-y-auto rounded-xl border-2 border-line bg-surface-sunk p-4 text-base leading-relaxed whitespace-pre-wrap" tabIndex={0}>
            {bodyOf(signed)}
          </article>
        </section>
      ) : current ? (
        <AgreementForm
          version={current.version}
          body={bodyOf(current)}
          bodyHash={current.body_hash}
          effectiveAt={current.effective_at}
        />
      ) : (
        // The state this ships in. Not an error, and it should not read like one.
        <Callout tone="neutral" className="space-y-3">
          <p className="leading-relaxed">{t("notPublished")}</p>
          <Link href="/">
            <Button variant="secondary" size="md">
              {tLegal("backHome")}
            </Button>
          </Link>
        </Callout>
      )}
    </main>
  );
}
