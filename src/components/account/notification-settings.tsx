"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import { setAvailableToHelpAction } from "@/app/actions/offers";
import { PushToggle } from "@/components/pwa/push-toggle";
import { Button, Callout, Card, Toggle } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

/** The columns this screen owns. Everything here is a boolean on `profiles`. */
type Prefs = {
  notify_recovery: boolean;
  notify_recovery_status: boolean;
  notify_chat: boolean;
  notify_community: boolean;
  notify_marketing: boolean;
};

type Device = {
  id: string;
  user_agent: string | null;
  created_at: string;
  last_used_at: string | null;
};

const DEFAULTS: Prefs = {
  notify_recovery: true,
  notify_recovery_status: true,
  notify_chat: true,
  notify_community: true,
  notify_marketing: false,
};

/**
 * Notification settings (spec section 8).
 *
 * Every switch saves the moment it is flipped. These are settings, not a form: somebody who turns
 * off 2am alerts and closes the tab should not discover next week that it never took because
 * there was a Save button below the fold.
 *
 * Optimistic, with a rollback. The control never shows a state the database disagrees with, which
 * matters more here than elsewhere — a switch that looks off and is on is how somebody gets woken
 * at 2am after deciding they would not be.
 *
 * WHAT IS NOT HERE
 *
 * A master "notifications off". The operating system already has one, it is the one people
 * actually trust, and duplicating it would leave two switches disagreeing about the same thing.
 */
export function NotificationSettings() {
  const t = useTranslations("notifySettings");
  const format = useFormatter();

  const [prefs, setPrefs] = useState<Prefs>(DEFAULTS);
  const [available, setAvailable] = useState(false);
  const [devices, setDevices] = useState<Device[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const supabase = supabaseBrowser();

    const [{ data: profile }, { data: subs }] = await Promise.all([
      supabase
        .from("profiles")
        .select(
          "notify_recovery, notify_recovery_status, notify_chat, notify_community, notify_marketing, available_to_help",
        )
        .maybeSingle(),
      // RLS on push_subscriptions is owner-only, so this returns this member's devices and
      // nobody else's. The keys are never selected: they are what a payload is encrypted to and
      // the browser has no use for them.
      supabase
        .from("push_subscriptions")
        .select("id, user_agent, created_at, last_used_at")
        .order("created_at", { ascending: false }),
    ]);

    if (profile) {
      const { available_to_help: willing, ...rest } = profile as Record<string, unknown>;
      setPrefs({ ...DEFAULTS, ...(rest as Partial<Prefs>) });
      setAvailable(Boolean(willing));
    }
    setDevices((subs as Device[] | null) ?? []);
    setLoaded(true);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function setPref<K extends keyof Prefs>(key: K, value: boolean) {
    const previous = prefs[key];
    setPrefs((p) => ({ ...p, [key]: value }));
    setError(null);

    const { error: saveError } = await supabaseBrowser()
      .from("profiles")
      .update({ [key]: value })
      .not("user_id", "is", null);

    if (saveError) {
      setPrefs((p) => ({ ...p, [key]: previous }));
      setError("save_failed");
    }
  }

  /**
   * Availability goes through the RPC, not a table write.
   *
   * Turning it on also creates the member's recovery capability row, which is what the dispatcher
   * matches against. A direct update would mark somebody willing with nothing to match through —
   * available, never rung, and no error anywhere.
   */
  async function setAvailability(next: boolean) {
    const previous = available;
    setAvailable(next);
    setError(null);

    const result = await setAvailableToHelpAction(next);
    if (!result.ok) {
      setAvailable(previous);
      setError("save_failed");
    }
  }

  async function forgetDevice(id: string) {
    const { error: deleteError } = await supabaseBrowser()
      .from("push_subscriptions")
      .delete()
      .eq("id", id);

    if (deleteError) {
      setError("save_failed");
      return;
    }
    await load();
  }

  if (!loaded) return null;

  return (
    <div className="space-y-4">
      {error ? <Callout tone="danger">{t("saveFailed")}</Callout> : null}

      <Card className="space-y-3">
        <PushToggle />
      </Card>

      {/* Per browser, not per account. Somebody with a phone and a laptop appears twice, and
          being able to drop one is how they stop a device they no longer have from buzzing. */}
      {devices.length > 0 ? (
        <Card className="space-y-3">
          <h2 className="text-xl font-semibold">{t("devicesTitle")}</h2>
          <ul className="space-y-2">
            {devices.map((device) => (
              <li
                key={device.id}
                className="flex items-center justify-between gap-3 rounded-field border border-line p-3"
              >
                <span>
                  <span className="block text-base">
                    {shortDevice(device.user_agent) ?? t("deviceUnknown")}
                  </span>
                  <span className="block text-sm text-ink-faint">
                    {device.last_used_at
                      ? t("deviceLastUsed", {
                          when: format.relativeTime(new Date(device.last_used_at)),
                        })
                      : t("deviceNeverUsed")}
                  </span>
                </span>
                <Button size="md" variant="quiet" onClick={() => void forgetDevice(device.id)}>
                  {t("deviceForget")}
                </Button>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}

      <Card className="space-y-3">
        <h2 className="text-xl font-semibold">{t("helpingTitle")}</h2>
        <Toggle
          checked={available}
          onChange={(v) => void setAvailability(v)}
          label={t("availableLabel")}
          hint={t("availableHint")}
        />
        <Toggle
          checked={prefs.notify_recovery}
          onChange={(v) => void setPref("notify_recovery", v)}
          label={t("nearbyLabel")}
          hint={t("nearbyHint")}
        />
      </Card>

      <Card className="space-y-3">
        <h2 className="text-xl font-semibold">{t("recoveryTitle")}</h2>
        <Toggle
          checked={prefs.notify_recovery_status}
          onChange={(v) => void setPref("notify_recovery_status", v)}
          label={t("statusLabel")}
          hint={t("statusHint")}
        />
        <Toggle
          checked={prefs.notify_chat}
          onChange={(v) => void setPref("notify_chat", v)}
          label={t("chatLabel")}
          hint={t("chatHint")}
        />
      </Card>

      <Card className="space-y-3">
        <h2 className="text-xl font-semibold">{t("otherTitle")}</h2>
        <Toggle
          checked={prefs.notify_community}
          onChange={(v) => void setPref("notify_community", v)}
          label={t("communityLabel")}
        />
        <Toggle
          checked={prefs.notify_marketing}
          onChange={(v) => void setPref("notify_marketing", v)}
          label={t("marketingLabel")}
          hint={t("marketingHint")}
        />
      </Card>

      <p className="text-sm text-ink-faint">{t("osNote")}</p>
    </div>
  );
}

/**
 * A user agent string is not a device name, and nobody wants to read one.
 *
 * Deliberately crude: enough to tell your phone from your laptop, which is the only question this
 * list has to answer. It is better to say "Android phone" than to print 180 characters of version
 * numbers at somebody trying to work out which device to drop.
 */
function shortDevice(ua: string | null): string | null {
  if (!ua) return null;
  if (/iPhone/i.test(ua)) return "iPhone";
  if (/iPad/i.test(ua)) return "iPad";
  if (/Android/i.test(ua)) return "Android phone";
  if (/Macintosh|Mac OS/i.test(ua)) return "Mac";
  if (/Windows/i.test(ua)) return "Windows PC";
  if (/Linux/i.test(ua)) return "Linux";
  return null;
}
