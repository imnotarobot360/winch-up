import type { Metadata } from "next";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "dataDeletion" });
  return { title: t("title") };
}

/**
 * How to delete your Winch Up account and what that actually removes.
 *
 * PUBLIC, AND THAT IS THE POINT. Meta requires a Data Deletion Instructions URL before a
 * Facebook app can go Live, and it has to be reachable without signing in -- a reviewer checks
 * it from a logged-out browser. /account already has the button, but it is behind auth, so it
 * cannot be the URL handed to Meta.
 *
 * It earns its place beyond that box-ticking: somebody who has lost access to their account
 * still needs a way to ask, and "how do I delete this" should never require logging back into
 * the thing you are trying to leave.
 *
 * Every claim here is checked against src/app/actions/deleteAccount. Writing "everything is
 * erased" would be the easy sentence and a false one -- audit rows and dispatch events survive
 * with a null actor, deliberately, and a deletion page that misrepresents that is worse than
 * no page.
 */
export default async function DataDeletionPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("dataDeletion");

  const steps = t.raw("steps") as string[];
  const removed = t.raw("removedItems") as string[];
  const kept = t.raw("keptItems") as string[];

  return (
    <main className="mx-auto w-full max-w-2xl space-y-6 px-4 py-8">
      <Link href="/" className="text-base underline underline-offset-4">
        {t("back")}
      </Link>

      <div>
        <h1 className="text-3xl font-bold">{t("title")}</h1>
        <p className="mt-2 text-base text-ink-soft">{t("intro")}</p>
      </div>

      <section className="space-y-3">
        <h2 className="text-xl font-bold">{t("howHeading")}</h2>
        <ol className="list-decimal space-y-2 pl-6 text-base leading-relaxed">
          {steps.map((s) => (
            <li key={s}>{s}</li>
          ))}
        </ol>
      </section>

      {/* The one thing that stops a deletion, and the reason, stated before somebody tries and
          is refused with no explanation. */}
      <Callout tone="neutral">
        <p className="font-bold">{t("blockedHeading")}</p>
        <p className="mt-1 text-sm leading-relaxed">{t("blockedBody")}</p>
      </Callout>

      <section className="space-y-3">
        <h2 className="text-xl font-bold">{t("removedHeading")}</h2>
        <ul className="list-disc space-y-1 pl-6 text-base leading-relaxed">
          {removed.map((s) => (
            <li key={s}>{s}</li>
          ))}
        </ul>
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-bold">{t("keptHeading")}</h2>
        <p className="text-base leading-relaxed text-ink-soft">{t("keptWhy")}</p>
        <ul className="list-disc space-y-1 pl-6 text-base leading-relaxed">
          {kept.map((s) => (
            <li key={s}>{s}</li>
          ))}
        </ul>
      </section>

      <section className="space-y-2">
        <h2 className="text-xl font-bold">{t("noAccessHeading")}</h2>
        <p className="text-base leading-relaxed">
          {t("noAccessBody")}{" "}
          {/* The address lives in the copy, as it does on /privacy. There is no SUPPORT_EMAIL
              constant, and adding one for a single page would put the same string in two
              places that can drift apart. */}
          <a
            href={`mailto:${t("supportEmail")}`}
            className="font-semibold underline underline-offset-4"
          >
            {t("supportEmail")}
          </a>
        </p>
      </section>

      <p className="text-sm text-ink-faint">
        <Link href="/privacy" className="underline underline-offset-4">
          {t("privacyLink")}
        </Link>
      </p>
    </main>
  );
}
