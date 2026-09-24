"use client";

import { useEffect, useMemo, useState } from "react";
import { useTranslations } from "next-intl";

import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * Screen 7 of the design reference: members near you who have said they are up for a call-out.
 *
 * EVERYONE HERE CHOSE TO BE
 *
 * nearby_members() lists a member only if they set BOTH "show my profile to other members" AND
 * "available to help". Either alone is not consent to appear in a directory -- being available
 * means "ring me when somebody near me is stuck", which is a different thing from "let strangers
 * page through me". The server enforces that; this component could not widen it if it tried.
 *
 * So the list starts nearly empty, and the empty state says why rather than implying the app is
 * broken. That is the honest state of a consent-based directory on its first day, and the
 * alternative -- seeding it with people who never agreed -- is not a trade worth making.
 *
 * Distances arrive already rounded, in whole miles under five and to the nearest five above. No
 * coordinates reach the browser at all.
 */
type Member = {
  user_id: string;
  display_name: string | null;
  avatar_path: string | null;
  home_region: string | null;
  vehicle_desc: string | null;
  vehicle_class: string | null;
  equipment: string[] | null;
  available: boolean;
  verified: boolean;
  miles: number | null;
};

const EQUIPMENT_FILTERS = ["winch", "kinetic_rope", "traction_boards", "tractor"] as const;

export function MembersList() {
  const t = useTranslations("members");
  const tEquip = useTranslations("enum.equipment");
  const [members, setMembers] = useState<Member[] | null>(null);
  const [query, setQuery] = useState("");
  const [equipment, setEquipment] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabaseBrowser().rpc("nearby_members", {
        p_equipment: equipment,
      });
      if (!alive) return;
      const result = data as { ok: boolean; members?: Member[] } | null;
      if (error || !result?.ok) {
        setFailed(true);
        setMembers([]);
        return;
      }
      setFailed(false);
      setMembers(result.members ?? []);
    })();
    return () => {
      alive = false;
    };
  }, [equipment]);

  // Filtering by name happens here rather than in the query: the list is capped at 100 rows, so
  // a round trip per keystroke would cost more than it saves and would leak what is being typed.
  const shown = useMemo(() => {
    if (!members) return null;
    const q = query.trim().toLowerCase();
    if (!q) return members;
    return members.filter((m) => (m.display_name ?? "").toLowerCase().includes(q));
  }, [members, query]);

  return (
    <div className="space-y-4">
      <input
        type="search"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder={t("searchPlaceholder")}
        aria-label={t("searchLabel")}
        className="tap-target w-full rounded-field border-2 border-line bg-surface-sunk px-4 text-base text-ink placeholder:text-ink-faint"
      />

      <div className="flex flex-wrap gap-2">
        <FilterChip active={equipment === null} onClick={() => setEquipment(null)}>
          {t("filterAll")}
        </FilterChip>
        {EQUIPMENT_FILTERS.map((key) => (
          <FilterChip key={key} active={equipment === key} onClick={() => setEquipment(key)}>
            {tEquip(key as never)}
          </FilterChip>
        ))}
      </div>

      {shown === null ? (
        <p className="py-8 text-center text-base text-ink-soft">{t("loading")}</p>
      ) : failed ? (
        <p className="rounded-field border-2 border-line bg-surface-sunk p-4 text-base text-ink-soft">
          {t("failed")}
        </p>
      ) : shown.length === 0 ? (
        <div className="space-y-2 rounded-field border-2 border-line bg-surface-sunk p-4">
          <p className="text-base font-semibold text-ink">
            {query || equipment ? t("emptyFiltered") : t("emptyTitle")}
          </p>
          {!query && !equipment ? (
            <p className="text-base text-ink-soft">{t("emptyBody")}</p>
          ) : null}
        </div>
      ) : (
        <ul className="space-y-3">
          {shown.map((m) => (
            <li key={m.user_id}>
              <Link
                href={`/members/${m.user_id}`}
                className="flex items-center gap-3 rounded-field border-2 border-line bg-surface-sunk p-3"
              >
                <Avatar name={m.display_name} />

                <div className="min-w-0 flex-1">
                  <div className="flex items-baseline justify-between gap-2">
                    <p className="truncate text-base font-bold text-ink">
                      {m.display_name ?? t("someone")}
                    </p>
                    {m.available ? (
                      <span className="shrink-0 rounded-full bg-good-tint px-2 py-0.5 text-xs font-semibold text-good">
                        {t("available")}
                      </span>
                    ) : null}
                  </div>

                  <p className="truncate text-sm text-ink-soft">
                    {[
                      m.miles != null ? t("milesAway", { miles: m.miles }) : null,
                      m.vehicle_desc,
                      m.home_region,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </p>

                  {m.equipment?.length ? (
                    <p className="mt-1 truncate text-xs text-ink-faint">
                      {m.equipment.slice(0, 3).map((e) => tEquip(e as never)).join(" · ")}
                    </p>
                  ) : null}
                </div>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function FilterChip({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`rounded-full border-2 px-3 py-1.5 text-sm font-semibold ${
        active ? "border-brand bg-brand-tint text-brand-text" : "border-line text-ink-soft"
      }`}
    >
      {children}
    </button>
  );
}

/**
 * Initials, not a photograph.
 *
 * profiles.avatar_path exists and points into a PRIVATE storage bucket, so rendering one needs a
 * signed URL per member per page load. That is a real feature with a real cost and it is not this
 * change; initials on the brand green read fine and never 404 into a broken-image icon.
 */
function Avatar({ name }: { name: string | null }) {
  const initials = (name ?? "?")
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "")
    .join("");

  return (
    <span
      aria-hidden
      className="flex size-12 shrink-0 items-center justify-center rounded-full border-2 border-line bg-trail text-base font-bold text-ink"
    >
      {initials}
    </span>
  );
}
