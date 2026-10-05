"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import { PushToggle } from "@/components/pwa/push-toggle";
import { Button, Callout, Card, Toggle } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

/** The columns this screen owns. Everything here is a boolean on `profiles`. */
type Prefs = {
  notify_recovery: boolean;
  notify_recovery_status: boolean;
  notify_chat: boolean;
  notify_community: boolean;
  notify_marketing: boolean;
  // Added 20261001002000. allow_direct_messages is who may START a conversation; notifying about
  // one is a separate switch, because being reachable and being interrupted are different things.
  allow_direct_messages: boolean;
  notify_direct_messages: boolean;
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
  allow_direct_messages: true,
  notify_direct_messages: true,
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
  /**
   * Recovery call-out texts: the one consent on this screen that is not a profiles column.
   *
   * Through the RPC, not a table write. `responders` holds a phone number and a home location and
   * has no update grant for `authenticated` at all -- every member-facing write to it goes through
   * a security definer function. The RPC is also where the opted-out invariant is kept: a trigger
   * forbids a row being both opted in and stamped with a STOP, so granting consent has to clear
   * that stamp, and it deliberately does NOT un-pause availability. Replying STOP paused them too,
   * and putting somebody back on call because they ticked a box is not what they asked for.
   */
  async function setRecoverySms(next: boolean) {
    const previous = smsState;
    setSmsState(next);
    setError(null);

    const { data, error: rpcError } = await supabaseBrowser().rpc("set_my_recovery_sms", {
      p_opt_in: next,
    });

    const result = data as { ok?: boolean } | null;
    if (rpcError || !result?.ok) {
      setSmsState(previous);
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
          checked={prefs.notify_recovery}
          onChange={(v) => void setPref("notify_recovery", v)}
          label={t("nearbyLabel")}
          hint={t("nearbyHint")}
        />
      </Card>

      <Card className="space-y-3">
        <h2 className="text-xl font-semibold">{t("dmTitle")}</h2>
        {/* WHO MAY REACH YOU comes before WHAT BUZZES, because it is the bigger decision and the
            one somebody comes to this screen looking for. Turning it off stops NEW conversations;
            the hint says so, because a member who expects it to silence an existing thread would
            be surprised by the next message. Blocking is what stops one person. */}
        <Toggle
          checked={prefs.allow_direct_messages}
          onChange={(v) => void setPref("allow_direct_messages", v)}
          label={t("allowDmLabel")}
          hint={t("allowDmHint")}
        />
        <Toggle
          checked={prefs.notify_direct_messages}
          onChange={(v) => void setPref("notify_direct_messages", v)}
          label={t("notifyDmLabel")}
          hint={t("notifyDmHint")}
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
        {/*
          THE ONLY WAY ANYBODY CAN AGREE TO BE TEXTED. Until 2026-10-04 responders.sms_opt_in
          defaulted to true and no screen showed it, so proving a phone number WAS consent and the
          only way to decline was to receive a text and reply STOP. The default is false now, which
          means without this switch nobody could ever be called out at all.

          Shown as an explanation rather than a control when there is no volunteer profile or no
          verified phone: a switch that cannot change anything is worse than a sentence saying why.
        */}
        {smsState === "no_profile" ? (
          <p className="text-sm text-ink-soft">{t("smsNoProfile")}</p>
        ) : smsState === "no_phone" ? (
          /*
            THE ONE WORTH SPELLING OUT. Somebody here has almost certainly verified a phone
            already -- on the account screen, where it does nothing for dispatch -- so "add your
            number" on its own reads as something they have done. It says which number is missing
            and links to the screen that writes it.
          */
          <Callout tone="neutral">
            <p>{t("smsNoPhone")}</p>
            <Link href="/join" className="mt-1 inline-block font-semibold underline underline-offset-4">
              {t("smsNoPhoneAction")}
            </Link>
          </Callout>
        ) : (
          <Toggle
            checked={smsState}
            onChange={(v) => void setRecoverySms(v)}
            label={t("smsLabel")}
            hint={t("smsHint")}
          />
        )}
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
