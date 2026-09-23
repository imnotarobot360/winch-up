"use client";

import { useCallback, useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * Turning on push notifications for this browser.
 *
 * Per browser, not per account, which is what the underlying model is: somebody with a phone and
 * a laptop registers twice and both buzz. The control reflects that honestly rather than
 * pretending it is one account-level switch.
 *
 * The permission prompt is only ever raised by a tap. A page that asks on load gets refused by
 * people who would have said yes if asked at a moment that made sense, and once refused the
 * browser will not ask again.
 */

const VAPID = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY ?? "";

/**
 * The VAPID key travels as base64url and the subscribe call wants raw bytes.
 *
 * Returns the ArrayBuffer rather than the view: TypeScript 5.7 made Uint8Array generic over its
 * backing buffer, and `Uint8Array<ArrayBufferLike>` no longer satisfies the `BufferSource` that
 * PushManager.subscribe declares. The buffer is the same bytes and needs no cast.
 */
function urlBase64ToBuffer(base64: string): ArrayBuffer {
  const padded = `${base64}${"=".repeat((4 - (base64.length % 4)) % 4)}`
    .replace(/-/g, "+")
    .replace(/_/g, "/");
  const raw = atob(padded);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i += 1) out[i] = raw.charCodeAt(i);
  return out.buffer as ArrayBuffer;
}

type State = "unsupported" | "unconfigured" | "denied" | "off" | "on" | "working";

export function PushToggle() {
  const t = useTranslations("push");
  const [state, setState] = useState<State>("working");
  const [error, setError] = useState<string | null>(null);

  const read = useCallback(async () => {
    if (!VAPID) return setState("unconfigured");
    if (
      typeof window === "undefined" ||
      !("serviceWorker" in navigator) ||
      !("PushManager" in window) ||
      !("Notification" in window)
    ) {
      // iOS below 16.4, and any desktop browser with push disabled. Saying so is better than a
      // button that does nothing when pressed.
      return setState("unsupported");
    }
    if (Notification.permission === "denied") return setState("denied");

    const registration = await navigator.serviceWorker.getRegistration();
    const existing = await registration?.pushManager.getSubscription();
    setState(existing ? "on" : "off");
  }, []);

  useEffect(() => {
    void read();
  }, [read]);

  async function enable() {
    setState("working");
    setError(null);
    try {
      const permission = await Notification.requestPermission();
      if (permission !== "granted") {
        setState(permission === "denied" ? "denied" : "off");
        return;
      }

      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager.subscribe({
        // Required by every browser: a push that shows nothing is not allowed, which suits this
        // app because there is no silent background work worth waking a phone for.
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToBuffer(VAPID),
      });

      const json = subscription.toJSON() as {
        endpoint?: string;
        keys?: { p256dh?: string; auth?: string };
      };

      const { data, error: rpcError } = await supabaseBrowser().rpc("save_push_subscription", {
        p_endpoint: json.endpoint ?? "",
        p_p256dh: json.keys?.p256dh ?? "",
        p_auth: json.keys?.auth ?? "",
        p_user_agent: navigator.userAgent,
      });

      if (rpcError || !(data as { ok?: boolean })?.ok) {
        // Registered with the browser but not with us: unsubscribe rather than leave a
        // subscription nothing will ever send to.
        await subscription.unsubscribe().catch(() => undefined);
        setError("save_failed");
        setState("off");
        return;
      }

      setState("on");
    } catch {
      setError("save_failed");
      setState("off");
    }
  }

  async function disable() {
    setState("working");
    try {
      const registration = await navigator.serviceWorker.getRegistration();
      const subscription = await registration?.pushManager.getSubscription();
      if (subscription) {
        await supabaseBrowser().rpc("delete_push_subscription", {
          p_endpoint: subscription.endpoint,
        });
        await subscription.unsubscribe().catch(() => undefined);
      }
      setState("off");
    } catch {
      setState("off");
    }
  }

  if (state === "unconfigured") return null;

  return (
    <div className="space-y-3">
      <div>
        <p className="text-lg font-semibold">{t("title")}</p>
        <p className="text-base text-ink-soft">{t("body")}</p>
      </div>

      {error ? <Callout tone="danger">{t("saveFailed")}</Callout> : null}

      {state === "unsupported" ? (
        <Callout tone="neutral">{t("unsupported")}</Callout>
      ) : state === "denied" ? (
        <Callout tone="neutral">{t("denied")}</Callout>
      ) : (
        <Button
          type="button"
          variant={state === "on" ? "secondary" : "primary"}
          disabled={state === "working"}
          onClick={() => void (state === "on" ? disable() : enable())}
        >
          {state === "on" ? t("turnOff") : t("turnOn")}
        </Button>
      )}

      {state === "on" ? (
        <p className="text-sm text-ink-faint">{t("thisDeviceOnly")}</p>
      ) : null}
    </div>
  );
}
