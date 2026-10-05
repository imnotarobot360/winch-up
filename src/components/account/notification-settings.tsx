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
  const [available, setAvailable] = useState(false);
  // null means "no recovery profile yet", which is a different thing from "opted out" and is
  // rendered differently: there is nothing to consent to until availability has been turned on.
  const [smsOptIn, setSmsOptIn] = useState<boolean | null>(null);
  // Kept so the saves below can name the row instead of leaning on RLS to scope them.
  const [userId, setUserId] = useState<string | null>(null);
  const [devices, setDevices] = useState<Device[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const supabase = supabaseBrowser();

    // BY user_id, resolved first. profiles_self_read is "own row OR app.is_admin()", so an admin
    // reads every profile row and maybeSingle() fails -- every switch on this screen then showed
    // its default to exactly one person, the owner. Same bug as /account and /account/location,
    // and invisible to tests because they all sign in as an ordinary member.
    const {
      data: { user },
    } = await supabase.auth.getUser();

    if (!user) {
      // A raw code, like the save paths below: this screen renders ONE message for any error and
      // ignores the value. Using t() here would also have put the translator back in the load
      // callback's dependencies, which is the thing its empty dep list exists to avoid.
      setError("load_failed");
      setLoaded(true);
      return;
    }

    setUserId(user.id);

    const [{ data: profile }, { data: subs }, { data: recovery }] = await Promise.all([
      supabase
        .from("profiles")
        // ONE STRING LITERAL, not a concatenation. supabase-js infers the row type from the select
        // text, and a `+` joined expression is not literal enough for it -- the result degrades to
        // GenericStringError and the destructure below stops compiling. Long line, working types.
        .select(
          "notify_recovery, notify_recovery_status, notify_chat, notify_community, notify_marketing, available_to_help, allow_direct_messages, notify_direct_messages",
        )
        .eq("user_id", user.id)
        .maybeSingle(),
      // RLS on push_subscriptions is owner-only, so this returns this member's devices and
      // nobody else's. The keys are never selected: they are what a payload is encrypted to and
      // the browser has no use for them.
      supabase
        .from("push_subscriptions")
        .select("id, user_agent, created_at, last_used_at")
        .order("created_at", { ascending: false }),
      // Consent to recovery TEXTS lives on responders, not profiles: it is a property of being a
      // volunteer, and a member who never turned availability on has no row here at all.
      // Filtered by user_id for the same reason as the profiles read above -- an admin can read
      // every responder row, and maybeSingle() fails on more than one.
      supabase
        .from("responders")
        .select("sms_opt_in, sms_opt_out_at, phone")
        .eq("user_id", user.id)
        .maybeSingle(),
    ]);

    if (profile) {
      const { available_to_help: willing, ...rest } = profile as Record<string, unknown>;
      setPrefs({ ...DEFAULTS, ...(rest as Partial<Prefs>) });
      setAvailable(Boolean(willing));
    }
    const row = recovery as { sms_opt_in: boolean; sms_opt_out_at: string | null; phone: string | null } | null;
    // No row, or no phone, both mean there is nothing to text: render the explanation rather than
    // a switch that cannot do anything.
    setSmsOptIn(row && row.phone ? Boolean(row.sms_opt_in) : null);

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

    // NAME THE ROW, and ask for it back.
    //
    // This said `.not("user_id", "is", null)` with no select, leaning on RLS to scope it. The
    // update policy here is user_id = auth.uid() with no admin clause, so nothing was ever written
    // to anybody else's row -- but a member whose profiles row is missing got a silent success and
    // a switch that moved and saved nothing, for ever. Same shape as the /account save that
    // reported "Saved" while writing nothing.
    const { data: written, error: saveError } = await supabaseBrowser()
      .from("profiles")
      .update({ [key]: value })
      .eq("user_id", userId ?? "")
      .select("user_id");

    if (saveError || !written || written.length === 0) {
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
    const previous = smsOptIn;
    setSmsOptIn(next);
    setError(null);

    const { data, error: rpcError } = await supabaseBrowser().rpc("set_my_recovery_sms", {
      p_opt_in: next,
    });

    const result = data as { ok?: boolean } | null;
    if (rpcError || !result?.ok) {
      setSmsOptIn(previous);
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
        {smsOptIn === null ? (
          <p className="text-sm text-ink-soft">{t("smsNoProfile")}</p>
        ) : (
          <Toggle
            checked={smsOptIn}
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
