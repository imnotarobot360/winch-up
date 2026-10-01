"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout, Card, Field, TextArea, TextInput } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

type Group = {
  id: string;
  slug: string;
  name: string;
  description: string | null;
  region: string | null;
  visibility: string;
  member_count: number;
  my_role: string | null;
};

/**
 * Groups: the local crews inside the wider community.
 *
 * The feature was built in phase 12 and never had a screen -- groups, group_members,
 * groups_list, create_group and group_membership have all been in the database for a week,
 * and events can already belong to a group. Same shape as events: "deferred" meant the UI.
 *
 * WHAT THIS DOES NOT HAVE, and deliberately:
 *
 *   A group page. There is nothing to put on one yet -- posts are not filed by group, and a
 *   group's events need the organiser flows that do not exist. A page listing a name and a
 *   member count twice is worse than a row that already says both.
 *
 *   A slug field. The schema wants a URL-safe slug and asking a volunteer for one is asking
 *   them to do the database's job; it is derived from the name here. Nothing links to a group
 *   by slug yet, so it stays internal until something does.
 *
 *   Private groups. group_visibility has more than one value and group_membership refuses to
 *   join anything that is not 'open'. Every group made here is open, because an invite flow is
 *   a feature and a Join button that refuses is a bug.
 */
export function GroupsList() {
  const t = useTranslations("groups");

  const [groups, setGroups] = useState<Group[] | null>(null);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [region, setRegion] = useState("");
  const [about, setAbout] = useState("");

  const load = useCallback(async (search: string) => {
    const { data, error: rpcError } = await supabaseBrowser().rpc("groups_list", {
      p_query: search.trim() || null,
    });

    if (rpcError) {
      setError("failed");
      return;
    }

    const result = data as { ok: boolean; error?: string; groups?: Group[] };
    if (!result.ok) {
      setError(result.error ?? "failed");
      return;
    }

    setError(null);
    setGroups(result.groups ?? []);
  }, []);

  useEffect(() => {
    // Debounced, so typing a county does not fire a query per keystroke on a phone with one bar.
    const timer = setTimeout(() => void load(query), 250);
    return () => clearTimeout(timer);
  }, [query, load]);

  async function membership(group: Group, join: boolean) {
    setBusy(group.id);
    setError(null);

    const { data, error: rpcError } = await supabaseBrowser().rpc("group_membership", {
      p_group_id: group.id,
      p_join: join,
    });

    setBusy(null);

    const result = data as { ok: boolean; error?: string } | null;
    if (rpcError || !result?.ok) {
      setError(result?.error ?? "failed");
      return;
    }

    await load(query);
  }

  async function create(event: React.FormEvent) {
    event.preventDefault();
    if (busy || name.trim().length < 2) return;

    setBusy("new");
    setError(null);

    const { data, error: rpcError } = await supabaseBrowser().rpc("create_group", {
      p_payload: {
        name: name.trim(),
        // Derived rather than asked for: lowercase, words joined by hyphens, anything else
        // dropped. The schema's own rule is ^[a-z0-9]+(-[a-z0-9]+)*$ and this produces it.
        slug: name
          .trim()
          .toLowerCase()
          .normalize("NFD")
          .replace(/[̀-ͯ]/g, "")
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/^-+|-+$/g, ""),
        region: region.trim() || null,
        description: about.trim() || null,
        visibility: "open",
      },
    });

    setBusy(null);

    const result = data as { ok: boolean; error?: string } | null;
    if (rpcError || !result?.ok) {
      setError(result?.error ?? "failed");
      return;
    }

    setName("");
    setRegion("");
    setAbout("");
    setOpen(false);
    await load(query);
  }

  return (
    <div className="space-y-4">
      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      <TextInput
        type="search"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder={t("searchPlaceholder")}
        aria-label={t("searchLabel")}
      />

      {open ? (
        <Card className="space-y-3">
          <form onSubmit={create} className="space-y-3">
            <Field label={t("newName")} hint={t("newNameHint")}>
              <TextInput value={name} onChange={(e) => setName(e.target.value)} maxLength={80} />
            </Field>
            <Field label={t("newRegion")} hint={t("newRegionHint")}>
              <TextInput
                value={region}
                onChange={(e) => setRegion(e.target.value)}
                maxLength={120}
              />
            </Field>
            <Field label={t("newAbout")}>
              <TextArea
                value={about}
                onChange={(e) => setAbout(e.target.value)}
                maxLength={1000}
                rows={3}
              />
            </Field>

            {/* Said before they press. The same rule as every other public text box here. */}
            <p className="text-sm text-ink-faint">{t("noContactNote")}</p>

            <div className="flex flex-wrap gap-2">
              <Button type="submit" disabled={busy !== null || name.trim().length < 2}>
                {busy === "new" ? t("working") : t("newSubmit")}
              </Button>
              <Button type="button" variant="secondary" onClick={() => setOpen(false)}>
                {t("newCancel")}
              </Button>
            </div>
          </form>
        </Card>
      ) : (
        <Button variant="secondary" onClick={() => setOpen(true)}>
          {t("newStart")}
        </Button>
      )}

      {groups === null ? (
        <p className="text-base text-ink-soft">{t("loading")}</p>
      ) : groups.length === 0 ? (
        <Card>
          <p className="text-base font-semibold text-ink">
            {query ? t("emptyFiltered") : t("emptyTitle")}
          </p>
          {!query ? <p className="mt-1 text-base text-ink-soft">{t("emptyBody")}</p> : null}
        </Card>
      ) : (
        <ul className="space-y-3">
          {groups.map((g) => (
            <li key={g.id}>
              <Card className="space-y-2">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-lg font-bold text-ink">{g.name}</p>
                    <p className="text-sm text-ink-soft">
                      {[
                        g.region,
                        t("members", { count: g.member_count }),
                        // Owner and organiser are the roles create_event checks, so saying
                        // which one somebody holds is not decoration.
                        g.my_role ? t(`role.${g.my_role}`) : null,
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </p>
                  </div>

                  <Button
                    variant={g.my_role ? "secondary" : "primary"}
                    disabled={busy === g.id || g.my_role === "owner"}
                    onClick={() => void membership(g, !g.my_role)}
                  >
                    {busy === g.id
                      ? t("working")
                      : g.my_role === "owner"
                        ? t("yours")
                        : g.my_role
                          ? t("leave")
                          : t("join")}
                  </Button>
                </div>

                {g.description ? (
                  <p className="whitespace-pre-wrap text-base text-ink-soft">{g.description}</p>
                ) : null}
              </Card>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
