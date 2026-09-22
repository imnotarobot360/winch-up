"use client";

import { useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { Button, Callout, Card } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * "I'm out here right now."
 *
 * One button, one point. There is no background reporting and nothing runs when this page is
 * closed — the volunteer presses it, the browser asks, and a single position is stored.
 *
 * That is a product decision, not a limitation to apologise for. Continuous tracking of people
 * who volunteer for free is a thing to be asked for explicitly, not slipped in, and the honest
 * way to not claim it is to not build it.
 *
 * The stored point expires from matching on its own, so forgetting to turn it off cannot leave
 * somebody matched from a trailhead they left on Sunday.
 */
export function LocationShare({
  sharing,
  sharedAt,
  onChange,
}: {
  sharing: boolean;
  sharedAt: string | null;
  onChange: () => void;
}) {
  const t = useTranslations("me.location");
  const format = useFormatter();
  const now = useNow({ updateInterval: 60_000 });

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function share() {
    if (busy) return;
    setError(null);

    if (!("geolocation" in navigator)) {
      setError("unsupported");
      return;
    }

    setBusy(true);

    navigator.geolocation.getCurrentPosition(
      async (position) => {
        const { data, error: rpcError } = await supabaseBrowser().rpc("update_my_location", {
          p_lat: position.coords.latitude,
          p_lng: position.coords.longitude,
          p_accuracy_m: Math.round(position.coords.accuracy),
        });

        setBusy(false);

        if (rpcError || (data as { ok?: boolean })?.ok === false) {
          setError((data as { error?: string })?.error ?? "failed");
          return;
        }
        onChange();
      },
      (geoError) => {
        setBusy(false);
        // 1 is PERMISSION_DENIED. Worth its own message: the fix is in browser settings, not
        // anything this page can do.
        setError(geoError.code === 1 ? "denied" : "unavailable");
      },
      { enableHighAccuracy: true, timeout: 15_000, maximumAge: 0 },
    );
  }

  async function forget() {
    setBusy(true);
    setError(null);
    const { error: rpcError } = await supabaseBrowser().rpc("forget_my_location");
    setBusy(false);
    if (rpcError) {
      setError("failed");
      return;
    }
    onChange();
  }

  return (
    <Card className="space-y-3">
      <h2 className="text-xl font-semibold">{t("title")}</h2>
      <p className="text-base text-ink-soft">{t("body")}</p>

      {error ? <Callout tone="danger">{t("errors." + error)}</Callout> : null}

      {sharing && sharedAt ? (
        <Callout tone="good">
          {t("sharedAt", { when: format.relativeTime(new Date(sharedAt), now) })}
        </Callout>
      ) : null}

      <div className="flex flex-col gap-2 sm:flex-row">
        <Button onClick={share} disabled={busy}>
          {busy ? t("working") : sharing ? t("update") : t("share")}
        </Button>
        {sharing ? (
          <Button variant="secondary" onClick={forget} disabled={busy}>
            {t("forget")}
          </Button>
        ) : null}
      </div>

      <p className="text-sm text-ink-faint">{t("note")}</p>
    </Card>
  );
}
