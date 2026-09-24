"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import { acceptOfferAction, declineOfferAction } from "@/app/actions/offers";
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
import { TeamPanel } from "@/components/recovery/team-panel";
import { ReportForm } from "@/components/incident/report-form";
import { RequestThread } from "@/components/messages/request-thread";
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

  /**
   * Choosing a volunteer.
   *
   * Goes through `run` like every other action on this page, which means it refetches
   * afterwards rather than patching state locally. That matters more here than elsewhere: two
   * offers can arrive while this screen is open, and the authoritative answer to "who is coming"
   * is the one the database gives after the row lock, not the one this component assumed.
   */
  async function acceptOffer(dispatchId: string) {
    await run(() => acceptOfferAction(token, dispatchId));
  }

  /** Passing on one volunteer. The request stays open and others can still offer. */
  async function declineOffer(dispatchId: string) {
    await run(() => declineOfferAction(token, dispatchId));
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

  /**
   * Somebody has offered and the requester has not chosen yet.
   *
   * This is the state that did not exist before the offers model, and it is the one the rest of
   * this screen has to be told about: the request is technically still 'unmatched', but telling
   * a stranded driver that nobody is coming — and listing paid tow operators underneath —
   * while a volunteer sits waiting to be picked is both wrong and expensive for them.
   */
  const awaitingChoice = !data.responder && data.offers.length > 0;

  // Absent on a database that has not had 20260923001600 applied yet. The app ships on a push to
  // main and the migrations go by hand, so there is a window where this page is newer than the
  // schema it is reading -- and an unguarded .length here is a TypeError on the one screen
  // somebody stuck in a field is watching.
  const team = data.team ?? [];

  return (
    <main className="mx-auto w-full max-w-xl space-y-5 px-4 py-6">
      {/* `unmatched` means the dispatcher ran out of people to ring. It used to also mean nobody
          had put their hand up, because those were the same thing. They are not any more: a
          member can find a request on /help and offer long after the rings are done. Left alone,
          this page told somebody "No volunteer yet" directly above "1 volunteer has offered". */}
      <header>
        <p className="font-mono text-base text-ink-faint">{data.short_code}</p>
        <h1 className="text-3xl font-bold leading-tight">
          {awaitingChoice
            ? t("awaitingChoiceTitle")
            : tEnum(`requestStatus.${data.status}`)}
        </h1>
        <p className="mt-1 text-base text-ink-soft">
          {awaitingChoice ? t("awaitingChoiceBody") : t(`headline.${data.status}`)}
        </p>
      </header>

      {data.status === "dispatching" || data.status === "submitted" ? (
        <Callout tone="brand">
          {t("notifying", {
            count: data.dispatch.notified_count,
            miles: data.dispatch.radius_miles ?? 15,
          })}
        </Callout>
      ) : null}

      {/* Spec section 8, steps 4 and 5. This is the screen the phase exists for: the person who
          is stuck decides who comes out, instead of the first volunteer to text winning the job
          before anybody told them somebody had replied. */}
      {/* Shown while the recovery is live, whether or not somebody has already been accepted.
          It used to stop at the first acceptance, which meant the requester could never build the
          team this phase is named after: the button that would have added a second helper was not
          on the screen, and the RPC had stopped returning the offers to put on it either. Under a
          team these people have not been passed over -- their offer stands -- and wanting the
          tractor as well, once you have seen how buried you are, is the ordinary case. */}
      {data.offers.length > 0 ? (
        <Card className="space-y-4 border-brand">
          <div>
            <h2 className="text-xl font-bold">
              {data.responder
                ? t("offersMoreTitle", { count: data.offers.length })
                : t("offersTitle", { count: data.offers.length })}
            </h2>
            <p className="mt-1 text-base text-ink-soft">
              {data.responder ? t("offersMoreBody") : t("offersBody")}
            </p>
          </div>

          <ul className="space-y-3">
            {data.offers.map((offer) => (
              <li key={offer.id} className="rounded-2xl border border-line p-4">
                <div className="flex items-baseline justify-between gap-2">
                  <p className="text-lg font-bold">
                    {offer.first_name}
                    {offer.verified ? (
                      <span className="ml-2 rounded-full bg-good-tint px-2 py-0.5 text-xs font-semibold uppercase tracking-wide text-good">
                        {t("offerVerified")}
                      </span>
                    ) : null}
                  </p>
                  {offer.distance_miles != null ? (
                    <span className="shrink-0 text-sm text-ink-soft">
                      {t("offerMiles", { miles: offer.distance_miles })}
                    </span>
                  ) : null}
                </div>

                <p className="text-base text-ink-soft">
                  {offer.vehicle_desc ?? tEnum(`vehicleClass.${offer.vehicle_class}`)}
                </p>

                {offer.eta_minutes != null ? (
                  <p className="mt-1 font-semibold">
                    {t("offerEta", { minutes: offer.eta_minutes })}
                  </p>
                ) : null}

                {offer.note ? (
                  <p className="mt-1 text-base text-ink-soft">{offer.note}</p>
                ) : null}

                <div className="mt-3 flex flex-wrap gap-3">
                  <Button
                    size="md"
                    disabled={pending}
                    onClick={() => void acceptOffer(offer.id)}
                  >
                    {data.responder
                      ? t("offerAdd", { name: offer.first_name })
                      : t("offerAccept", { name: offer.first_name })}
                  </Button>
                  <Button
                    size="md"
                    variant="secondary"
                    disabled={pending}
                    onClick={() => void declineOffer(offer.id)}
                  >
                    {t("offerDecline")}
                  </Button>
                </div>
              </li>
            ))}
          </ul>

          {/* Said once, here, because accepting is the moment their number is handed over and
              there is no taking it back. */}
          <p className="text-sm text-ink-faint">
            {data.responder ? t("offersMorePrivacyNote") : t("offersPrivacyNote")}
          </p>
        </Card>
      ) : null}

      {/* Who is coming. Sits above the contact card on purpose: with a team, "a volunteer is on
          the way" is no longer the whole answer, and the person waiting wants to know a tractor
          is coming as well as a winch before they want a phone number. Read-only here -- a
          helper's own controls live in the thread, which only participants can open. */}
      {team.length > 1 ? (
        <Card className="border-good">
          <TeamPanel requestId={data.id} team={team} />
        </Card>
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
            className="tap-target flex w-full items-center justify-center rounded-field text-center bg-brand text-lg font-bold text-on-brand"
          >
            {t("callResponder", { phone: formatUsPhone(data.responder.phone) })}
          </a>
        </Card>
      ) : null}

      {/* Suppressed while somebody is waiting to be picked. The paid list is there for a driver
          nobody has offered to help; showing it next to a free volunteer's offer would push
          somebody towards paying for a tow they may not need. */}
      {data.status === "unmatched" && !awaitingChoice ? (
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

      {data.id ? (

        <div className="mt-8">

          <RequestThread requestId={data.id} closed={isClosed(data.status)} />

        </div>

      ) : null}


      {/* Quiet, and last. Most people never need it, and a report form sitting open on a

          status page reads as an accusation waiting to happen. */}

      <div className="mt-10">

        <ReportForm token={token} />

      </div>

    </main>
  );
}
