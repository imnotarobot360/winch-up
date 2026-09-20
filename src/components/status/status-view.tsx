"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import {
  cancelRequestAction,
  markRecoveredAction,
  thankResponderAction,
} from "@/app/actions/status";
import {
  Button,
  Callout,
  Card,
  Field,
  TextArea,
} from "@/components/ui/primitives";
import { mapAppUrl } from "@/lib/geo";
import { isClosed, type StatusView as StatusViewData } from "@/lib/types/status";
import { formatUsPhone } from "@/lib/utils";

const POLL_MS = 15_000;

/**
 * The page a stranded driver sits on while they wait.
 *
 * It polls rather than holding a socket: on one bar of signal a websocket that quietly dies
 * looks identical to nothing happening, and this page's whole job is to show that something is
 * happening. Polling pauses while the tab is hidden and stops once the job is closed.
 */
export function StatusView({
  token,
  initial,
}: {
  token: string;
  initial: StatusViewData;
}) {
  const t = useTranslations("status");
  const tEnum = useTranslations("enum");
  const format = useFormatter();

  const [data, setData] = useState(initial);
  const [pending, setPending] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [showRecoverForm, setShowRecoverForm] = useState(false);
  const [thankYou, setThankYou] = useState("");
  const [copied, setCopied] = useState(false);

  const closed = isClosed(data.status);

  const refresh = useCallback(async () => {
    try {
      const response = await fetch(`/api/r/${token}`, { cache: "no-store" });
      if (!response.ok) return;
      setData((await response.json()) as StatusViewData);
    } catch {
      // Offline or a dropped request. The next tick tries again.
    }
  }, [token]);

  useEffect(() => {
    if (closed) return;

    const timer = setInterval(() => {
      if (document.visibilityState === "visible") void refresh();
    }, POLL_MS);

    const onVisible = () => {
      if (document.visibilityState === "visible") void refresh();
    };

    document.addEventListener("visibilitychange", onVisible);

    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [closed, refresh]);

  async function run(action: () => Promise<{ ok: boolean; error?: string }>) {
    setPending(true);
    setActionError(null);

    const result = await action();

    if (!result.ok) {
      setActionError(result.error ?? "server_error");
    } else {
      await refresh();
      setShowRecoverForm(false);
    }

    setPending(false);
  }

  async function share() {
    const url = window.location.href;
    const title = t("shareTitle", { code: data.short_code });

    if (navigator.share) {
      try {
        await navigator.share({ title, url });
        return;
      } catch {
        // Cancelled, or unsupported in this context. Fall through to copying.
      }
    }

    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      setTimeout(() => setCopied(false), 2500);
    } catch {
      setCopied(false);
    }
  }

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      <header>
        <p className="font-mono text-base text-ink-faint">{data.short_code}</p>
        <h1 className="text-3xl font-bold leading-tight">
          {tEnum(`requestStatus.${data.status}`)}
        </h1>
        <p className="mt-1 text-base text-ink-soft">{t(`headline.${data.status}`)}</p>
      </header>

      {data.status === "dispatching" || data.status === "submitted" ? (
        <Callout tone="brand">
          {t("notifying", {
            count: data.dispatch.notified_count,
            miles: data.dispatch.radius_miles ?? 15,
          })}
        </Callout>
      ) : null}

      {data.responder ? (
        <Card className="space-y-3 border-good">
          <div>
            <p className="text-sm font-semibold uppercase tracking-wide text-ink-faint">
              {t("responderTitle")}
            </p>
            <p className="text-2xl font-bold">{data.responder.first_name}</p>
            <p className="text-base text-ink-soft">
              {data.responder.vehicle_desc ??
                tEnum(`vehicleClass.${data.responder.vehicle_class}`)}
            </p>
            {data.eta_minutes != null ? (
              <p className="mt-1 text-lg font-semibold">
                {t("eta", { minutes: data.eta_minutes })}
              </p>
            ) : null}
          </div>

          <a
            href={`tel:${data.responder.phone}`}
            className="tap-target flex w-full items-center justify-center rounded-field bg-brand text-lg font-bold text-white"
          >
            {t("callResponder", { phone: formatUsPhone(data.responder.phone) })}
          </a>
        </Card>
      ) : null}

      {data.status === "unmatched" ? (
        <Card className="space-y-3 border-danger">
          <h2 className="text-xl font-bold">{t("unmatchedTitle")}</h2>
          <p className="text-base text-ink-soft">{t("unmatchedBody")}</p>

          {data.pro_options && data.pro_options.length > 0 ? (
            <ul className="space-y-3">
              {data.pro_options.map((option) => (
                <li key={option.name} className="rounded-field border border-line p-3">
                  <p className="font-semibold">{option.name}</p>
                  {option.blurb ? (
                    <p className="text-sm text-ink-soft">{option.blurb}</p>
                  ) : null}
                  {option.phone ? (
                    <a
                      href={`tel:${option.phone}`}
                      className="mt-2 inline-block font-semibold underline underline-offset-4"
                    >
                      {formatUsPhone(option.phone)}
                    </a>
                  ) : null}
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-base text-ink-soft">{t("noProOptions")}</p>
          )}
        </Card>
      ) : null}

      <Card className="space-y-3">
        <h2 className="text-xl font-semibold">{t("timelineTitle")}</h2>
        <ol className="space-y-3">
          {data.timeline.map((entry, index) => (
            <li key={`${entry.type}-${index}`} className="flex gap-3">
              <span
                aria-hidden
                className="mt-2 h-3 w-3 shrink-0 rounded-full bg-brand"
              />
              <span>
                <span className="block font-medium">{tEnum(`event.${entry.type}`)}</span>
                <span className="block text-sm text-ink-faint">
                  {format.dateTime(new Date(entry.at), {
                    hour: "numeric",
                    minute: "2-digit",
                  })}
                </span>
              </span>
            </li>
          ))}
        </ol>
      </Card>

      <Card className="space-y-3">
        <h2 className="text-xl font-semibold">{t("detailsTitle")}</h2>
        <p className="text-base">
          {tEnum(`vehicleClass.${data.vehicle.class}`)}
          {data.vehicle.make ? ` · ${data.vehicle.make}` : ""}
          {data.vehicle.model ? ` ${data.vehicle.model}` : ""}
        </p>
        <p className="text-base">
          {tEnum(`stuckType.${data.situation.stuck_type}`)}
          {data.situation.stuck_depth
            ? ` · ${tEnum(`stuckDepth.${data.situation.stuck_depth}`)}`
            : ""}
        </p>
        <a
          href={mapAppUrl(data.lat, data.lng)}
          target="_blank"
          rel="noreferrer"
          className="inline-block font-mono text-sm underline underline-offset-4"
        >
          {data.lat.toFixed(5)}, {data.lng.toFixed(5)}
        </a>

        {data.photo_urls.length > 0 ? (
          <ul className="grid grid-cols-3 gap-2">
            {data.photo_urls.map((url) => (
              <li key={url}>
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src={url}
                  alt=""
                  className="aspect-square w-full rounded-field border border-line object-cover"
                />
              </li>
            ))}
          </ul>
        ) : null}
      </Card>

      {actionError ? <Callout tone="danger">{t(`errors.${actionError}`)}</Callout> : null}

      {!closed ? (
        <div className="space-y-3">
          {showRecoverForm ? (
            <Card className="space-y-3">
              <Field
                label={t("thankYouLabel")}
                hint={t("thankYouHint")}
                htmlFor="thank-you"
              >
                <TextArea
                  id="thank-you"
                  value={thankYou}
                  maxLength={300}
                  onChange={(event) => setThankYou(event.target.value)}
                />
              </Field>
              <Button
                type="button"
                disabled={pending}
                onClick={() => run(() => markRecoveredAction(token, thankYou))}
              >
                {t("confirmRecovered")}
              </Button>
              <Button
                type="button"
                variant="quiet"
                onClick={() => setShowRecoverForm(false)}
              >
                {t("back")}
              </Button>
            </Card>
          ) : (
            <Button type="button" onClick={() => setShowRecoverForm(true)}>
              {t("markRecovered")}
            </Button>
          )}

          <Button
            type="button"
            variant="danger"
            disabled={pending}
            onClick={() => {
              if (window.confirm(t("cancelConfirm"))) {
                void run(() => cancelRequestAction(token));
              }
            }}
          >
            {t("cancelRequest")}
          </Button>
        </div>
      ) : null}

      {data.status === "recovered" && data.responder && !data.thanked ? (
        <Card className="space-y-3">
          <Field label={t("thankYouLabel")} htmlFor="thank-late">
            <TextArea
              id="thank-late"
              value={thankYou}
              maxLength={300}
              onChange={(event) => setThankYou(event.target.value)}
            />
          </Field>
          <Button
            type="button"
            disabled={pending || thankYou.trim().length === 0}
            onClick={() => run(() => thankResponderAction(token, thankYou))}
          >
            {t("sendThanks")}
          </Button>
        </Card>
      ) : null}

      <Button type="button" variant="secondary" onClick={share}>
        {copied ? t("linkCopied") : t("shareLink")}
      </Button>

      <p className="pb-6 text-center text-sm text-ink-faint">
        {t("autoRefresh", { seconds: POLL_MS / 1000 })}
      </p>

      <p className="sr-only" aria-live="polite">
        {tEnum(`requestStatus.${data.status}`)}
      </p>

    </main>
  );
}
