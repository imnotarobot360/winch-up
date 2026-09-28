import { getTranslations } from "next-intl/server";

import { Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseServer } from "@/lib/supabase/server";

/**
 * Renders a versioned legal document straight from the `waivers` table.
 *
 * The text is in the database rather than in this repo because a request records which version
 * was accepted. If the copy lived here, "what exactly did this person agree to in March" would
 * be a git-archaeology question instead of a foreign key.
 *
 * Read through the session client, not the service role. The `waivers` policy already exposes
 * the current version to anyone, this page has no business holding a privileged key, and the
 * `cookies()` call keeps the page dynamic — an admin who publishes a new version needs it live
 * immediately, not at the next deploy.
 */
export async function LegalDocument({
  slug,
  locale,
  title,
  review = "placeholder",
  children,
}: {
  slug: "requester_waiver" | "responder_waiver" | "rules";
  locale: string;
  title: string;
  /**
   * Which health warning to put above the text.
   *
   * `placeholder` (the default) is the red one: this document is scaffolding and nobody should
   * rely on a word of it. That is still true of both waivers.
   *
   * `unreviewed` is the measured one /privacy uses: the text is real and accurate, it simply
   * has not been through an attorney. Only pass this when the body genuinely is finished --
   * and note that passing it wrongly does not work anyway, see below.
   */
  review?: "placeholder" | "unreviewed";
  /** Rendered inside <main>, below the versioned text. For sections that are not part of the
   *  accepted document -- carrier-required SMS disclosure, for one. Outside <main> they would be
   *  skipped by anybody using a skip-to-content link. */
  children?: React.ReactNode;
}) {
  const t = await getTranslations("legal");

  const supabase = await supabaseServer();

  const { data } = await supabase
    .from("waivers")
    .select("version, body_en, body_es, effective_at")
    .eq("slug", slug)
    .eq("is_current", true)
    .maybeSingle();

  const body = data ? (locale === "es" ? data.body_es : data.body_en) : null;

  /**
   * The caller says which banner it wants, but the TEXT gets the final say.
   *
   * A page claiming its document is merely "not reviewed by an attorney" while the document
   * itself reads PLACEHOLDER is the one failure that actually matters here: it is the app
   * telling somebody the words are real when they are not. So if the stored body still says
   * placeholder in either language, the loud banner comes back regardless of what was passed.
   *
   * This is not hypothetical tidiness. These bodies are edited in the database, by an admin,
   * long after nobody is looking at this file -- publishing scaffolding into a slug whose page
   * had been softened is exactly the mistake that would otherwise ship silently.
   */
  const looksUnfinished = /placeholder|texto provisional/i.test(
    `${data?.body_en ?? ""} ${data?.body_es ?? ""}`,
  );
  const tone = review === "unreviewed" && !looksUnfinished ? "unreviewed" : "placeholder";

  return (
    <main className="mx-auto w-full max-w-2xl space-y-5 px-4 py-8">
      <Link href="/" className="text-base underline underline-offset-4">
        {t("backHome")}
      </Link>

      <h1 className="text-3xl font-bold">{title}</h1>

      {tone === "placeholder" ? (
        <Callout tone="danger">
          <p className="font-bold">{t("reviewBanner")}</p>
          <p className="mt-1 text-sm">{t("reviewExplainer")}</p>
        </Callout>
      ) : (
        <Callout tone="neutral">
          <p className="font-bold">{t("unreviewedBanner")}</p>
          <p className="mt-1 text-sm">{t("unreviewedDocExplainer")}</p>
        </Callout>
      )}

      {body ? (
        <>
          <p className="text-sm text-ink-faint">
            {t("version", { version: data!.version })}
          </p>
          <article className="whitespace-pre-wrap text-base leading-relaxed">{body}</article>
        </>
      ) : (
        <p className="text-base text-ink-soft">{t("missing")}</p>
      )}

      {children}
    </main>
  );
}
