"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { deleteAccount } from "@/app/actions/account";
import { PushToggle } from "@/components/pwa/push-toggle";
import { Button, Callout, Card, Field, TextInput, Toggle } from "@/components/ui/primitives";
import { Link, useRouter } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

type Profile = {
  display_name: string | null;
  home_region: string | null;
  notify_recovery: boolean;
  notify_community: boolean;
  notify_marketing: boolean;
  profile_public: boolean;
};

const EMPTY: Profile = {
  display_name: "",
  home_region: "",
  notify_recovery: true,
  notify_community: true,
  notify_marketing: false,
  profile_public: false,
};

/**
 * Profile editing and account deletion.
 *
 * The profile save goes straight from the browser to Postgres: RLS restricts it to the signed-in
 * user's own row, and the UPDATE grant lists only the editable columns, so there is nothing a
 * server action would add except a hop. Deletion is a server action, because removing a row from
 * auth.users needs the service role.
 */
export function AccountForm({ email }: { email: string }) {
  const t = useTranslations("account");
  const router = useRouter();

  const [profile, setProfile] = useState<Profile>(EMPTY);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  // Kept out of `profile` on purpose: it saves through an RPC on toggle, not with the form.
  const [availableToHelp, setAvailableToHelp] = useState(false);
  const [availabilityError, setAvailabilityError] = useState(false);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data } = await supabaseBrowser()
        .from("profiles")
        .select("display_name, home_region, notify_recovery, notify_community, notify_marketing, profile_public, available_to_help")
        .maybeSingle();
      if (!alive) return;
      if (data) {
        const { available_to_help: willing, ...rest } = data as Record<string, unknown>;
        setProfile({ ...EMPTY, ...(rest as Partial<Profile>) });
        setAvailableToHelp(Boolean(willing));
      }
      setLoaded(true);
    })();
    return () => {
      alive = false;
    };
  }, []);

  function set<K extends keyof Profile>(key: K, value: Profile[K]) {
    setProfile((p) => ({ ...p, [key]: value }));
    setSaved(false);
  }

  /**
   * The availability switch saves immediately rather than on form submit.
   *
   * It is a switch, not a field — somebody flipping "I can help" and walking away should not
   * discover later that it never took because they did not press Save. The optimistic update is
   * rolled back if the RPC refuses, so the control never shows a state the database disagrees
   * with.
   */
  async function setAvailability(next: boolean) {
    const previous = availableToHelp;
    setAvailableToHelp(next);
    setAvailabilityError(false);

    const { data, error: rpcError } = await supabaseBrowser().rpc("set_available_to_help", {
      p_available: next,
    });

    if (rpcError || !(data as { ok?: boolean })?.ok) {
      setAvailableToHelp(previous);
      setAvailabilityError(true);
    }
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
        notify_recovery: profile.notify_recovery,
        notify_community: profile.notify_community,
        notify_marketing: profile.notify_marketing,
        profile_public: profile.profile_public,
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

  if (!loaded) return null;

  return (
    <div className="space-y-6">
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

        <Card className="space-y-3">
          <h2 className="text-xl font-semibold">{t("vehiclesTitle")}</h2>
          <p className="text-base text-ink-soft">{t("vehiclesBody")}</p>
          <Link
            href="/account/vehicles"
            className="tap-target flex w-full items-center justify-center rounded-field border-2 border-line px-4 text-center text-lg font-semibold"
          >
            {t("vehiclesCta")}
          </Link>
        </Card>

        {/* Spec section 5. Deliberately NOT part of the form below, and not written through the
            profiles update: turning this on also has to create the member's recovery capability
            row, which is what app.candidates() matches against. A direct table write would set
            the flag and leave them willing with nothing to be matched through — marked available
            and never rung, with no error anywhere. So it saves on toggle, through the RPC that
            does both. */}
        <Card className="space-y-3">
          <h2 className="text-xl font-semibold">{t("availableTitle")}</h2>
          <Toggle
            checked={availableToHelp}
            onChange={(v) => void setAvailability(v)}
            label={t("availableLabel")}
            hint={t("availableHint")}
          />
          {availabilityError ? (
            <p className="text-sm text-danger">{t("availableFailed")}</p>
          ) : null}
        </Card>

        <Card className="space-y-3">
          <PushToggle />
        </Card>

        <Card className="space-y-3">
          <h2 className="text-xl font-semibold">{t("notifyTitle")}</h2>
          <Toggle
            checked={profile.notify_recovery}
            onChange={(v) => set("notify_recovery", v)}
            label={t("notifyRecovery")}
            hint={t("notifyRecoveryHint")}
          />
          <Toggle
            checked={profile.notify_community}
            onChange={(v) => set("notify_community", v)}
            label={t("notifyCommunity")}
          />
          <Toggle
            checked={profile.notify_marketing}
            onChange={(v) => set("notify_marketing", v)}
            label={t("notifyMarketing")}
            hint={t("notifyMarketingHint")}
          />
        </Card>

        <Card className="space-y-3">
          <h2 className="text-xl font-semibold">{t("privacyTitle")}</h2>
          <Toggle
            checked={profile.profile_public}
            onChange={(v) => set("profile_public", v)}
            label={t("profilePublic")}
            hint={t("profilePublicHint")}
          />
        </Card>

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
