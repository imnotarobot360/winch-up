import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getTranslations, setRequestLocale } from "next-intl/server";

import { MemberActions } from "@/components/members/member-actions";
import { supabaseServer } from "@/lib/supabase/server";
import { signVehiclePhoto, signVehiclePhotos } from "@/lib/vehicle-photos";

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
  /** Their primary rig. A path into a private bucket -- signed below, never rendered raw. */
  rig_photo_path: string | null;
  // Added by 20261001001300, so OPTIONAL. The frontend deploys on a push and so do the migrations,
  // but either can lag the other, and a profile page is not where somebody should discover that
  // with a TypeError. Read through ?? throughout.
  posts?: number | null;
  comments?: number | null;
  rig_count?: number | null;
};

/** One rig a member chose to show. vehicles.notes is deliberately not in here -- see the RPC. */
type Rig = {
  id: string;
  make: string | null;
  model: string | null;
  year: number | null;
  vehicle_class: string | null;
  drivetrain: string | null;
  tire_size: string | null;
  has_winch: boolean | null;
  winch_capacity_lb: number | null;
  equipment: string[] | null;
  photo_path: string | null;
  is_primary: boolean | null;
};

/**
 * Screen 8 of the design reference: one member's profile.
 *
 * Server-rendered, so member_profile() runs before anything reaches the browser. The RPC answers
 * not_found for "no such member", "suspended" and "blocked" alike, so this page cannot be used to
 * tell those apart -- or to test whether an account exists.
 *
 * WHAT CHANGED when every profile became visible (20261001001100): nothing on this page about what
 * is shown. The gate it used to sit behind is gone, so this is now reachable for every active
 * member rather than the handful who had opted in twice. The fields are the same fields.
 *
 * What the reference shows and this does not: a rating and a review count. Neither exists in this
 * product. Inventing a reputation for a volunteer is worse than a plainer card -- somebody would
 * choose who to trust with their stuck truck based on it.
 *
 * Recoveries IS shown, because the dispatch path maintains that column on completion. It is the one
 * number here that is true.
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
  const tDrive = await getTranslations("enum.drivetrain");

  const supabase = await supabaseServer();
  const { data } = await supabase.rpc("member_profile", { p_user_id: userId });
  const result = data as { ok: boolean; member?: Member } | null;

  if (!result?.ok || !result.member) notFound();
  const m = result.member;
  // Whole years since joining. 365.25 so a leap year cannot tip somebody back under the line on
  // their own anniversary.
  const years = m.member_since
    ? Math.floor((Date.now() - new Date(m.member_since).getTime()) / (365.25 * 24 * 60 * 60 * 1000))
    : 0;

  // Signed here rather than in the RPC: the bucket is private and the URL expires, so minting it
  // any earlier would hand out a link that is already stale.
  const rigPhoto = await signVehiclePhoto(m.rig_photo_path);

  // The rigs they marked for community display. A second call rather than part of member_profile():
  // a member may have several, each with its own photo path, and those have to be signed in a batch
  // here anyway. Skipped when the profile says there are none -- which is one fewer round trip on
  // most profiles, and the count comes back in the call that was already being made.
  const rigsResponse =
    (m.rig_count ?? 0) > 0 ? await supabase.rpc("member_rigs", { p_user_id: userId }) : null;
  const rigsResult = rigsResponse?.data as { ok: boolean; rigs?: Rig[] } | null;
  const rigs = rigsResult?.ok ? (rigsResult.rigs ?? []) : [];
  const rigPhotos = await signVehiclePhotos(rigs.map((r) => r.photo_path));

  return (
    <main className="mx-auto w-full max-w-xl px-4 py-6">
      {/* The reference opens with a wide vehicle photograph, and as of 20260928000900 there is one:
          members put a photo on their primary rig. When they have not, this falls back to the brand
          field rather than a grey rectangle pretending to be a truck -- a surface that does not
          pretend beats a placeholder that does. */}
      {rigPhoto ? (
        // Not next/image: the src is a signed URL that expires in ten minutes, so the optimiser
        // would cache a link that outlives its own validity.
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={rigPhoto}
          alt={t("rigPhotoAlt", { name: m.display_name ?? t("someone") })}
          className="-mx-4 -mt-6 mb-4 h-44 w-[calc(100%+2rem)] max-w-none object-cover"
        />
      ) : (
        <div className="-mx-4 -mt-6 mb-4 h-28 bg-trail" />
      )}

      <header className="space-y-2">
        <div className="flex items-baseline justify-between gap-3">
          <h1 className="text-3xl font-bold text-ink">{m.display_name ?? t("someone")}</h1>
          {/* Availability is shown only when the member enabled it (§2). It stopped being the price
              of appearing in the directory and went back to meaning what it says. */}
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

      {/* Two stats, not the reference three.
          The reference has Recoveries / Rating / Years. There is no rating in this product -- nobody
          is scored, and inventing a 5.0 to fill a tile would be a number the database cannot
          produce. Years is real: member_since has been in member_profile() since 20260924000100.

          Under a year reads "<1" rather than rounding to 0. A volunteer who joined last month has
          not been here zero years, and a profile that says so undersells the one thing a stranger
          deciding whether to trust them can check. */}
      <section className="mt-6 grid grid-cols-2 gap-3">
        <div className="rounded-field border-2 border-line bg-surface-sunk p-4">
          <p className="text-2xl font-bold text-ink">{m.recoveries ?? 0}</p>
          <p className="text-sm text-ink-soft">{t("recoveries")}</p>
        </div>

        {m.member_since ? (
          <div className="rounded-field border-2 border-line bg-surface-sunk p-4">
            <p className="text-2xl font-bold text-ink">{years >= 1 ? years : t("underOneYear")}</p>
            <p className="text-sm text-ink-soft">{t("years", { count: years })}</p>
          </div>
        ) : null}
      </section>

      {/* Community activity (§2, §3): what they have put into the feed. member_profile() counts only
          status = 'visible', because counting a hidden post would publish a moderation decision as
          arithmetic. Shown only when there is something to show -- a pair of zeroes on a new
          member's profile reads as a judgement rather than a fact. */}
      {(m.posts ?? 0) > 0 || (m.comments ?? 0) > 0 ? (
        <section className="mt-3 grid grid-cols-2 gap-3">
          <div className="rounded-field border-2 border-line bg-surface-sunk p-4">
            <p className="text-2xl font-bold text-ink">{m.posts ?? 0}</p>
            <p className="text-sm text-ink-soft">{t("posts", { count: m.posts ?? 0 })}</p>
          </div>
          <div className="rounded-field border-2 border-line bg-surface-sunk p-4">
            <p className="text-2xl font-bold text-ink">{m.comments ?? 0}</p>
            <p className="text-sm text-ink-soft">{t("comments", { count: m.comments ?? 0 })}</p>
          </div>
        </section>
      ) : null}

      {/* THEIR RIGS, with the photographs they marked for community display. This is the part a
          stranger actually looks at -- whether the truck coming toward them is the one in the
          picture. vehicles.show_in_community defaults to TRUE: the spec lists vehicle details among
          what members may see, and defaulting it off would repeat the mistake the directory itself
          has just climbed out of. */}
      {rigs.length > 0 ? (
        <section className="mt-6 space-y-3">
          <h2 className="text-lg font-semibold text-ink">{t("rigs")}</h2>
          {rigs.map((rig) => {
            const photo = rig.photo_path ? rigPhotos.get(rig.photo_path) : null;
            const title = [rig.year, rig.make, rig.model].filter(Boolean).join(" ");
            return (
              <article
                key={rig.id}
                className="overflow-hidden rounded-field border-2 border-line bg-surface-sunk"
              >
                {photo ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    src={photo}
                    alt={t("rigPhotoAlt", { name: title || m.display_name || t("someone") })}
                    className="h-40 w-full object-cover"
                  />
                ) : null}
                <div className="space-y-1 p-3">
                  <p className="text-base font-bold text-ink">
                    {title || t("aRig")}
                    {rig.is_primary ? (
                      <span className="ml-2 text-xs font-semibold text-ink-faint">
                        {t("primaryRig")}
                      </span>
                    ) : null}
                  </p>
                  <p className="text-sm text-ink-soft">
                    {[
                      rig.drivetrain ? tDrive(rig.drivetrain as never) : null,
                      rig.tire_size,
                      rig.has_winch && rig.winch_capacity_lb
                        ? t("winchLb", { lb: rig.winch_capacity_lb })
                        : rig.has_winch
                          ? t("hasWinch")
                          : null,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </p>
                  {rig.equipment?.length ? (
                    <p className="text-xs text-ink-faint">
                      {rig.equipment.map((e) => tEquip(e as never)).join(" · ")}
                    </p>
                  ) : null}
                </div>
              </article>
            );
          })}
        </section>
      ) : null}

      {/* No Message button. The reference has one, and there is no member-to-member messaging in
          this product -- the only conversation that exists is the one attached to a recovery, which
          is gated on being a participant in it. The spec says "send messages where messaging is
          enabled", and it is not enabled, so this says where a conversation does open instead. A
          button that opened nothing, or worse opened a channel to a stranger, is not the thing to
          add on the way past. */}
      <p className="mt-6 text-sm text-ink-faint">{t("howToReach")}</p>

      {/* Report, and block (§6). Last on the page on purpose: it is what somebody reaches for when
          the rest of the profile has already gone wrong for them. */}
      <MemberActions userId={m.user_id} name={m.display_name ?? t("someone")} />
    </main>
  );
}
