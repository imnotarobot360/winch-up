"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { deleteAccount } from "@/app/actions/account";
import {
  IconAlert,
  IconBoards,
  IconCheck,
  IconDoc,
  IconHook,
  IconPin,
  IconRing,
  IconShackle,
  IconTruck,
  IconWinch,
} from "@/components/ui/icons";
import { Avatar } from "@/components/ui/avatar";
import { MenuList } from "@/components/ui/menu-list";
import { Button, Callout, Card, Field, TextInput } from "@/components/ui/primitives";
import { useRouter } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

type Profile = {
  display_name: string | null;
  home_region: string | null;
};

const EMPTY: Profile = {
  display_name: "",
  home_region: "",
};

/**
 * Profile editing and account deletion.
 *
 * Notification preferences deliberately do NOT round-trip through this form any more. They moved
 * to /account/notifications, and leaving them in the save payload meant a stale copy loaded here
 * would silently revert whatever that screen had just set.
 *
 * The profile save goes straight from the browser to Postgres: RLS restricts it to the signed-in
 * user's own row, and the UPDATE grant lists only the editable columns, so there is nothing a
 * server action would add except a hop. Deletion is a server action, because removing a row from
 * auth.users needs the service role.
 */
export function AccountForm({
  email,
  canModerate = false,
}: {
  email: string;
  /** Resolved on the server. Hides a row; it does not grant anything -- /moderation gates itself. */
  canModerate?: boolean;
}) {
  const t = useTranslations("account");
  const router = useRouter();

  const [profile, setProfile] = useState<Profile>(EMPTY);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [loadFailed, setLoadFailed] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const { data, error: loadError } = await supabaseBrowser()
          .from("profiles")
          .select("display_name, home_region")
          .maybeSingle();

        if (!alive) return;
        if (loadError) setLoadFailed(loadError.message);
        if (data) setProfile({ ...EMPTY, ...data });
      } catch (cause) {
        // Anything that throws before the request is even made lands here -- a misconfigured
        // client, a blocked fetch. Without this the rejection was unhandled, setLoaded never
        // ran, and the whole screen rendered as nothing at all.
        if (alive) setLoadFailed(cause instanceof Error ? cause.message : String(cause));
      } finally {
        // In a finally, so the screen always stops waiting. This is the actual bug: the load
        // could fail in a way that skipped this line, and `if (!loaded) return null` then meant
        // a blank page with no spinner, no error and nothing in the console.
        if (alive) setLoaded(true);
      }
    })();
    return () => {
      alive = false;
    };
  }, []);

  function set<K extends keyof Profile>(key: K, value: Profile[K]) {
    setProfile((p) => ({ ...p, [key]: value }));
    setSaved(false);
  }

  async function save(event: React.FormEvent) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);

    const { error: saveError } = await supabaseBrowser()
      .from("profiles")
      .update({
        display_name: profile.display_name?.trim() || null,
        home_region: profile.home_region?.trim() || null,
      })
      .not("user_id", "is", null);

    setBusy(false);

    if (saveError) {
      // The CHECK that rejects a phone number or link in a display name surfaces as 23514.
      setError(saveError.code === "23514" ? "contact_in_name" : "save_failed");
      return;
    }

    setSaved(true);
  }

  async function remove() {
    setBusy(true);
    setError(null);
    const result = await deleteAccount();
    setBusy(false);

    if (!result.ok) {
      setError(result.error);
      setConfirming(false);
      return;
    }

    router.push("/");
    router.refresh();
  }

  // Was `return null`, which is why this screen appeared to be missing entirely rather than
  // broken. A skeleton says "wait"; nothing says "this feature does not exist".
  if (!loaded) {
    return (
      <div className="space-y-3" aria-busy="true" aria-live="polite">
        <span className="sr-only">{t("loading")}</span>
        <div className="h-12 animate-pulse rounded-field bg-surface-sunk" />
        <div className="h-12 animate-pulse rounded-field bg-surface-sunk" />
        <div className="h-32 animate-pulse rounded-2xl bg-surface-sunk" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Screen 12's header: who this is, above the settings rather than buried in a form field.
          Two things the reference has that this does not, both deliberate.

          No photograph. profiles.avatar_path points into a PRIVATE bucket and would need a signed
          URL per page load; initials read fine and never 404 into a broken-image icon.

          No @handle. There is no handle in this schema and inventing one on the screen would be a
          label for something a member cannot set, change or be found by. */}
      <div className="flex items-center gap-4">
        <Avatar name={profile.display_name} size="lg" />
        <div className="min-w-0">
          <p className="truncate text-xl font-bold text-ink">
            {profile.display_name?.trim() || t("noName")}
          </p>
          <p className="truncate text-base text-ink-soft">
            {profile.home_region?.trim() || t("noRegion")}
          </p>
          <p className="truncate text-sm text-ink-faint">{email}</p>
        </div>
      </div>

      {loadFailed ? <Callout tone="danger">{t("loadFailed")}</Callout> : null}

      <form onSubmit={save} className="space-y-4">
        {error && error !== "open_request" && error !== "active_job" ? (
          <Callout tone="danger">{t(`errors.${error}`)}</Callout>
        ) : null}
        {saved ? <Callout tone="good">{t("saved")}</Callout> : null}

        <Card className="space-y-4">
          <Field label={t("emailLabel")} hint={t("emailHint")}>
            <TextInput value={email} readOnly disabled />
          </Field>

          <Field label={t("nameLabel")} hint={t("nameHint")}>
            <TextInput
              value={profile.display_name ?? ""}
              onChange={(e) => set("display_name", e.target.value)}
              maxLength={60}
            />
          </Field>

          <Field label={t("regionLabel")} hint={t("regionHint")}>
            <TextInput
              value={profile.home_region ?? ""}
              onChange={(e) => set("home_region", e.target.value)}
              maxLength={80}
            />
          </Field>
        </Card>

        {/* Screen 12's menu. Every row goes to a route that exists, and the labels say where
            they actually go rather than repeating the reference's -- there is no standalone
            "My equipment" screen in this product, it is part of the volunteer details form, so
            that is what the row is called and where it leads. A menu item that opens nothing is
            worse than one fewer menu item.

            Two of these were full cards with a heading, a paragraph and a button each. Six of
            those would be two screens of scrolling for six links. */}
        <MenuList
          items={[
            {
              href: "/account/vehicles",
              label: t("menuVehicles"),
              hint: t("menuVehiclesHint"),
              icon: <IconTruck size={22} />,
            },
            {
              href: "/join",
              label: t("menuEquipment"),
              hint: t("menuEquipmentHint"),
              icon: <IconWinch size={22} />,
            },
            {
              href: "/me",
              label: t("menuRecoveries"),
              hint: t("menuRecoveriesHint"),
              icon: <IconHook size={22} />,
            },
            {
              href: "/trails",
              label: t("menuTrails"),
              hint: t("menuTrailsHint"),
              icon: <IconPin size={22} />,
            },
            {
              href: "/trails?saved=1",
              label: t("menuSavedTrails"),
              hint: t("menuSavedTrailsHint"),
              icon: <IconBoards size={22} />,
            },
            {
              href: "/account/notifications",
              label: t("menuNotifications"),
              hint: t("menuNotificationsHint"),
              icon: <IconRing size={22} />,
            },
            {
              href: "/account/security",
              label: t("menuSecurity"),
              hint: t("menuSecurityHint"),
              icon: <IconShackle size={22} />,
            },
            {
              href: "/account/blocked",
              label: t("menuBlocked"),
              hint: t("menuBlockedHint"),
              icon: <IconAlert size={22} />,
            },
            // Only for people who can act on it. The page refuses everybody else anyway.
            ...(canModerate
              ? [
                  {
                    href: "/moderation",
                    label: t("menuModeration"),
                    hint: t("menuModerationHint"),
                    icon: <IconCheck size={22} />,
                  },
                ]
              : []),
            {
              href: "/resources",
              label: t("menuResources"),
              hint: t("menuResourcesHint"),
              icon: <IconDoc size={22} />,
            },
          ]}
        />

        {/* THE PRIVACY CARD IS GONE, and so is profiles.profile_public with it.

            It held one switch -- "Show my profile to other members" -- which the owner removed:
            every active member is now in the directory. Nothing replaces it, because there is no
            decision left to offer here, and a card headed Privacy containing nothing says the
            opposite of the truth.

            What a member still controls is on /account/notifications (whether they are called
            out), /me (whether they share a live position) and /account/blocked (who cannot see
            them). Being listed was never what protected anybody: their phone, their email and
            their coordinates are kept out of the directory by what the RPC selects, not by a
            switch. See docs/member-directory-audit.md. */}
        <Button type="submit" size="lg" disabled={busy}>
          {busy ? t("working") : t("save")}
        </Button>
      </form>

      <Card className="space-y-3">
        <h2 className="text-xl font-semibold">{t("deleteTitle")}</h2>
        <p className="text-base text-ink-soft">{t("deleteBody")}</p>
        {/* What survives, said before the button rather than discovered afterwards. A promise
            of erasure that is quietly partial is worse than an honest one. */}
        <p className="text-base text-ink-soft">{t("deleteKept")}</p>

        {error === "open_request" || error === "active_job" ? (
          <Callout tone="danger">{t(`errors.${error}`)}</Callout>
        ) : null}

        {confirming ? (
          <div className="space-y-3">
            <Callout tone="danger">{t("deleteConfirm")}</Callout>
            <div className="flex flex-col gap-2 sm:flex-row">
              <Button variant="danger" size="lg" onClick={remove} disabled={busy}>
                {busy ? t("working") : t("deleteYes")}
              </Button>
              <Button variant="secondary" size="lg" onClick={() => setConfirming(false)} disabled={busy}>
                {t("deleteNo")}
              </Button>
            </div>
          </div>
        ) : (
          <Button variant="danger" size="lg" onClick={() => setConfirming(true)}>
            {t("deleteStart")}
          </Button>
        )}
      </Card>
    </div>
  );
}
