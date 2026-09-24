import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { supabaseServer } from "@/lib/supabase/server";

export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations("memberProfile");
  return { title: t("title"), robots: { index: false, follow: false } };
}

type Member = {
  user_id: string;
  display_name: string | null;
  home_region: string | null;
  vehicle_desc: string | null;
  vehicle_class: string | null;
  equipment: string[] | null;
  available: boolean;
  verified: boolean;
  recoveries: number | null;
  member_since: string | null;
  miles: number | null;
};

/**
 * Screen 8 of the design reference: one member's public profile.
 *
 * Server-rendered, so member_profile() runs before anything reaches the browser and a member who
 * opted out never has their details serialised into a page at all. The RPC answers not_found for
 * "no such member", "not public" and "not available" alike, so this page cannot be used to test
 * whether an account exists.
 *
 * What the reference shows and this does not: a rating, a review count, and years of experience.
 * None of those exist in this product. Inventing a reputation for a volunteer is worse than a
 * plainer card -- somebody would choose who to trust with their stuck truck based on it.
 *
 * Recoveries IS shown, because the dispatch path maintains that column on completion. It is the
 * one number here that is true.
 */
export default async function MemberProfilePage({
  params,
}: {
  params: Promise<{ locale: string; userId: string }>;
}) {
  const { locale, userId } = await params;
  setRequestLocale(locale);

  const t = await getTranslations("memberProfile");
  const tEquip = await getTranslations("enum.equipment");

  const supabase = await supabaseServer();
  const { data } = await supabase.rpc("member_profile", { p_user_id: userId });
  const result = data as { ok: boolean; member?: Member } | null;

  if (!result?.ok || !result.member) notFound();
  const m = result.member;

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-6">
      {/* The reference opens with a wide vehicle photograph. There is no member photography in
          this product -- avatar_path points into a private bucket and most members have none --
          so this is the brand field instead. A grey placeholder pretending to be a truck would
          be worse than a surface that does not pretend. */}
      <div className="-mx-4 -mt-6 mb-4 h-28 bg-trail" />

      <header className="space-y-2">
        <div className="flex items-baseline justify-between gap-3">
          <h1 className="text-3xl font-bold text-ink">{m.display_name ?? t("someone")}</h1>
          {m.available ? (
            <span className="shrink-0 rounded-full bg-good-tint px-3 py-1 text-sm font-semibold text-good">
              {t("available")}
            </span>
          ) : null}
        </div>

        <p className="text-base text-ink-soft">
          {[
            m.miles != null ? t("milesAway", { miles: m.miles }) : null,
            m.home_region,
            m.vehicle_desc,
          ]
            .filter(Boolean)
            .join(" · ")}
        </p>

        {m.verified ? (
          <p className="text-sm text-ink-faint">{t("verified")}</p>
        ) : (
          <p className="text-sm text-ink-faint">{t("notVerified")}</p>
        )}
      </header>

      {m.equipment?.length ? (
        <section className="mt-6">
          <h2 className="text-lg font-semibold text-ink">{t("equipment")}</h2>
          <ul className="mt-2 flex flex-wrap gap-2">
            {m.equipment.map((e) => (
              <li
                key={e}
                className="rounded-field border-2 border-line bg-surface-sunk px-3 py-2 text-sm font-semibold text-ink"
              >
                {tEquip(e as never)}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <section className="mt-6 rounded-field border-2 border-line bg-surface-sunk p-4">
        <p className="text-2xl font-bold text-ink">{m.recoveries ?? 0}</p>
        <p className="text-sm text-ink-soft">{t("recoveries")}</p>
      </section>

      {/* No Message button. The reference has one, and there is no member-to-member messaging in
          this product -- the only conversation that exists is the one attached to a recovery,
          which is gated on being a participant in it. A button that opened nothing, or worse
          opened a channel to a stranger, is not the thing to add on the way past. */}
      <p className="mt-6 text-sm text-ink-faint">{t("howToReach")}</p>
    </main>
  );
}
