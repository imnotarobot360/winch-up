"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Avatar } from "@/components/ui/avatar";
import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * Screen 7 of the design reference: the member directory.
 *
 * EVERYONE IS HERE NOW
 *
 * This used to say the opposite, and it was true when it was written: nearby_members() listed a
 * member only if they had set both "show my profile to other members" and "available to help",
 * and the list started nearly empty as a result. The owner removed that gate -- every active
 * member is in the directory, and 20261001001100 is where that is enforced.
 *
 * Availability is still shown, as a chip, and only when the member enabled it. It stopped being
 * the price of appearing and went back to meaning what it says: ring me when somebody near me is
 * stuck. Being in this list does not put anybody on call -- app.candidates() reads the switch,
 * not this list.
 *
 * Suspended accounts, deleted accounts, anybody you blocked and anybody who blocked you are all
 * absent, and none of that is this component's doing: it could not widen what the server returns
 * if it tried.
 * * Distances arrive already rounded, in whole miles under five and to the nearest five above. No
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

  // SEARCH RUNS ON THE SERVER, debounced, and that is a change forced by opening the directory.
  //
  // It used to filter the fetched rows in the browser, with a reasonable argument: the list is
  // capped at a hundred, so a round trip per keystroke cost more than it saved. That argument
  // held while the directory was opt-in and nearly empty. With every member in it, a hundred
  // rows is a page of the membership rather than all of it -- and searching a page while
  // appearing to search the directory is the kind of wrong that looks like a missing member
  // rather than a missing feature.
  //
  // The escaping lives in app.like_contains, so an underscore or a percent sign typed into the
  // box is a character and not a wildcard.
  const [debounced, setDebounced] = useState("");

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(query.trim()), 250);
    return () => clearTimeout(timer);
  }, [query]);

  // AND IT FALLS BACK WHEN THE SCHEMA IS BEHIND THE FRONTEND.
  //
  // This is not hypothetical and it was not free. 20261001001100 added p_query to
  // nearby_members(); the frontend went live in production and the migration did not, so every
  // call carried a parameter the function did not have, PostgREST answered PGRST202, and the
  // directory showed "Could not load members" to everybody for the better part of an hour.
  //
  // Migrations and the app deploy from the same push, in that order, and usually about ninety
  // seconds apart -- but either half can lag or fail, and the cost of being strict here is a dead
  // screen rather than a missing search box. So: on a failure, ask again without p_query and
  // filter in the browser. That is the behaviour this component had until today, it is correct for
  // a membership small enough to fit in one page, and once the function exists the fallback never
  // runs again.
  const [serverSearch, setServerSearch] = useState(true);

  useEffect(() => {
    let alive = true;
    (async () => {
      const client = supabaseBrowser();
      const withQuery = serverSearch && debounced.length > 0;

      let { data, error } = await client.rpc(
        "nearby_members",
        withQuery
          ? { p_equipment: equipment, p_query: debounced }
          : { p_equipment: equipment },
      );

      // PGRST202 is "no function with those arguments", which here means the migration has not
      // landed. Anything else -- a dead connection, a refused grant -- is a real failure and is
      // reported as one rather than quietly retried.
      if (withQuery && error && (error as { code?: string }).code === "PGRST202") {
        if (!alive) return;
        setServerSearch(false);
        ({ data, error } = await client.rpc("nearby_members", { p_equipment: equipment }));
      }

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
  }, [equipment, debounced, serverSearch]);
  // Normally no second filter: the rows that came back ARE the answer to what was typed, and
  // filtering them again would quietly re-impose the limit the server search removed. The
  // exception is the fallback above, where the server was never given the query at all.
  const shown =
    serverSearch || !members || debounced.length === 0
      ? members
      : members.filter((m) =>
          (m.display_name ?? "").toLowerCase().includes(debounced.toLowerCase()),
        );
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
