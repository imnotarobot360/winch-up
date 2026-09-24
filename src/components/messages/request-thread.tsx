"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { TeamPanel, type TeamMember } from "@/components/recovery/team-panel";
import { Button, Callout, Card, TextArea } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";
import {
  enqueue,
  flush,
  listQueued,
  type QueuedMessage,
  type SendResult,
} from "@/lib/chat/outbox";

/**
 * The confirmed recovery point, for the people driving to it.
 *
 * Optional throughout: it is absent on a database without 20260923002700, and null on a scrubbed
 * recovery whose exact pin has been destroyed. Both mean "no card", and neither is an error.
 */
type RecoveryLocation = {
  lat: number;
  lng: number;
  accuracy_m: number | null;
  source: string | null;
  note: string | null;
  county: string | null;
};

/**
 * Exactly the labels in the location_source enum. Checked rather than trusted: next-intl throws
 * on a missing key, so an enum value added in a migration without matching copy would break the
 * whole thread rather than one line of it. Unknown values render raw, which is ugly and honest.
 */
const LOCATION_SOURCES = new Set([
  "gps",
  "map_pin",
  "coordinates",
  "google_maps_link",
  "what3words",
  "admin_intake",
]);

type Message = {
  id: string;
  sender_role: "requester" | "responder" | "admin" | "system";
  body: string | null;
  attachment_path: string | null;
  attachment_type: string | null;
  /** A first name. Null for a system line, which belongs to nobody. */
  sender_name: string | null;
  /** This reader's own idempotency key, or null on somebody else's message. */
  client_id: string | null;
  created_at: string;
  mine: boolean;
};

/**
 * The floor. Fifteen seconds while the socket is down, a minute while it is up.
 *
 * The slow one is not an optimisation, it is the check that the socket is telling the truth: a
 * websocket that silently stopped delivering looks exactly like a quiet conversation, and a
 * minute is the longest this is willing to be wrong about that.
 */
const POLL_MS = 15_000;
const POLL_MS_LIVE = 60_000;

/** Errors that mean "do not retry this". Anything else is treated as no answer. */
const TERMINAL = new Set(["not_found", "empty", "too_long", "closed", "bad_attachment_type"]);

/**
 * The conversation for one recovery: the person who is stuck and everybody helping them.
 *
 * It used to be exactly two people. A real recovery often is not -- a winch truck and a tractor
 * turn up together -- so the thread is now the whole team, and messages carry who said them.
 *
 * This component holds no permission logic at all. It asks request_thread() for the thread; if
 * the caller has no live row in recovery_participants the RPC answers not_found and this renders
 * nothing. A signed-out visitor holding a shared status link therefore sees no trace of it --
 * not a locked panel, not a sign-in prompt, nothing. There is nothing to be curious about. The
 * same is true of a helper who withdrew: they keep their history, they stop seeing what is said
 * next.
 *
 * DELIVERY
 *
 * Two channels, and the slow one is the one that is trusted. Supabase Realtime makes a message
 * appear the moment it is written; a poll underneath it means a socket that dies on one bar of
 * signal degrades to late messages rather than to no messages. The socket only ever triggers a
 * reload -- nothing is rendered from its payload -- so a dropped or duplicated event cannot put
 * the thread into a state the server does not agree with.
 *
 * Outbound goes through a local queue keyed by an id minted before the first attempt, so a retry
 * over bad signal cannot post the same line twice. Nothing is drawn as delivered until the server
 * says so: a queued message renders as waiting, visibly different from one that arrived.
 */
export function RequestThread({ requestId, closed }: { requestId: string; closed?: boolean }) {
  const t = useTranslations("thread");
  const format = useFormatter();
  const now = useNow({ updateInterval: 30_000 });

  // useNow ticks on an interval, so something written seconds ago can be newer than the clock it
  // is measured against, and next-intl then honestly reports it as "in 40 seconds". Measuring
  // from whichever is later reads as "now".
  const relative = (iso: string) => {
    const at = new Date(iso);
    return format.relativeTime(at, at > now ? at : now);
  };

  const [messages, setMessages] = useState<Message[] | null>(null);
  const [team, setTeam] = useState<(TeamMember & { is_me?: boolean })[]>([]);
  // The server decides this, not the caller: a recovery that is over stops accepting messages
  // whatever the page thinks its state is.
  const [readOnly, setReadOnly] = useState(false);
  const [body, setBody] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [location, setLocation] = useState<RecoveryLocation | null>(null);
  const [queued, setQueued] = useState<QueuedMessage[]>([]);
  const [live, setLive] = useState(false);
  const [offline, setOffline] = useState(false);
  const endRef = useRef<HTMLDivElement>(null);
  // A flush must not overlap itself: the poll, the socket and the online event can all fire at
  // once, and three concurrent passes over the same queue is how you get the duplicate the key
  // exists to prevent.
  const flushing = useRef(false);

  const load = useCallback(async () => {
    const { data, error: rpcError } = await supabaseBrowser().rpc("request_thread", {
      p_request_id: requestId,
    });

    if (rpcError) {
      // Signed out, the session expired, or the network is gone. Not a participant either way,
      // and the queue is left alone: this says nothing about whether a send would work.
      setMessages(null);
      return;
    }

    const result = data as {
      ok: boolean;
      messages?: Message[];
      team?: (TeamMember & { is_me?: boolean })[];
      read_only?: boolean;
      location?: RecoveryLocation | null;
    };

    setMessages(result.ok ? (result.messages ?? []) : null);
    setTeam(result.ok ? (result.team ?? []) : []);
    setReadOnly(Boolean(result.read_only));
    setLocation(result.ok ? (result.location ?? null) : null);
  }, [requestId]);

  const send = useCallback(async (item: QueuedMessage): Promise<SendResult> => {
    const { data, error: rpcError } = await supabaseBrowser().rpc("send_request_message", {
      p_payload: { request_id: item.requestId, body: item.body, client_id: item.clientId },
    });

    // No answer. Could be no signal, could be the reply that was lost -- and it does not matter,
    // because the next attempt carries the same key.
    if (rpcError) return { kind: "unreachable" };

    const result = data as { ok: boolean; error?: string } | null;
    if (result?.ok) return { kind: "sent" };

    const reason = result?.error ?? "failed";
    return TERMINAL.has(reason) ? { kind: "rejected", error: reason } : { kind: "unreachable" };
  }, []);

  const drain = useCallback(async () => {
    if (flushing.current) return;
    flushing.current = true;
    try {
      const outcome = await flush(requestId, send);
      setQueued(listQueued(requestId));
      if (outcome.rejected.length > 0) setError(outcome.rejected[0].error);
      if (outcome.sent > 0) await load();
    } finally {
      flushing.current = false;
    }
  }, [requestId, send, load]);

  // First paint: drain anything left over from a previous session before drawing, so a message
  // that actually landed is not briefly shown as still waiting.
  useEffect(() => {
    setQueued(listQueued(requestId));
    void (async () => {
      await drain();
      await load();
    })();
  }, [requestId, drain, load]);

  useEffect(() => {
    const timer = setInterval(() => {
      void load();
      void drain();
    }, live ? POLL_MS_LIVE : POLL_MS);
    return () => clearInterval(timer);
  }, [load, drain, live]);

  // Realtime, as a broadcast rather than postgres_changes.
  //
  // postgres_changes would authorise each subscriber by running RLS on request_messages, and that
  // table has no policy and no grant to authenticated -- it is served only through the RPC. The
  // subscription would connect, report SUBSCRIBED and deliver nothing, which is worse than not
  // having it. Granting SELECT on the table to fix that would hand every participant the
  // sender_user_id of everyone else, which is exactly what the RPC declines to return.
  //
  // So the database sends a nudge carrying nothing but the request id
  // (20260923002200_realtime_broadcast.sql) and the content is re-read through the RPC. The
  // socket never becomes a second, less careful way to read a conversation.
  //
  // Untestable against the local stack, which has no realtime server, so it is written to be
  // harmless when it never connects: the only thing an event does is ask for a reload, and the
  // poll above is doing that anyway.
  useEffect(() => {
    const client = supabaseBrowser();

    // A private channel is authorised by a policy on realtime.messages, which needs the member's
    // JWT on the socket rather than the anon key the client was constructed with. Without this
    // the subscription is refused and the poll quietly carries the thread -- the failure is
    // invisible, which is why it is worth the extra line.
    void client.realtime.setAuth();

    const channel = client
      .channel(`recovery:${requestId}`, { config: { private: true } })
      .on("broadcast", { event: "changed" }, () => void load())
      .subscribe((status) => {
        // Only SUBSCRIBED slows the poll down. Anything else -- closed, errored, timed out --
        // puts it back to fifteen seconds, which is the whole reason the floor exists.
        setLive(status === "SUBSCRIBED");
      });

    return () => {
      setLive(false);
      void client.removeChannel(channel);
    };
  }, [requestId, load]);

  // Coming back from a tunnel. navigator.onLine is only ever trusted in the negative direction:
  // it says nothing useful about whether the server is reachable, but "the OS thinks the radio
  // just came back" is a good moment to try again.
  useEffect(() => {
    const update = () => setOffline(typeof navigator !== "undefined" && !navigator.onLine);
    update();
    const back = () => {
      update();
      void drain();
      void load();
    };
    window.addEventListener("online", back);
    window.addEventListener("offline", update);
    return () => {
      window.removeEventListener("online", back);
      window.removeEventListener("offline", update);
    };
  }, [drain, load]);

  useEffect(() => {
    endRef.current?.scrollIntoView({ block: "nearest" });
  }, [messages?.length, queued.length]);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    const text = body.trim();
    if (!text || busy) return;

    setBusy(true);
    setError(null);

    // Queued first, then sent. The other order loses the message if the tab is closed during the
    // request, and this is a product for people whose phone is about to die.
    enqueue(requestId, text);
    setBody("");
    setQueued(listQueued(requestId));

    await drain();
    setBusy(false);
  }

  // Not a participant, or signed out. Render nothing at all.
  if (messages === null) return null;

  // A queued message the server already has. Happens after a reload while the queue is
  // non-empty: the flush has not confirmed it yet, but the thread already shows it.
  const landed = new Set(messages.map((m) => m.client_id).filter(Boolean) as string[]);
  const pending = queued.filter((q) => !landed.has(q.clientId));

  return (
    <Card className="space-y-3">
      <div>
        <h2 className="text-xl font-semibold">{t("title")}</h2>
        <p className="mt-1 text-sm text-ink-faint">{t("privateNote")}</p>
      </div>

      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

      {offline ? <Callout tone="neutral">{t("offline")}</Callout> : null}

      {/* This member's own controls only -- the roster is rendered once, by the page above. The
          first version showed the full panel here too, which put the same list of helpers on
          screen twice, one card apart. Controls live here because only participants can open the
          thread, so only participants see buttons that act on their own membership. */}
      {team.some((m) => m.is_me && m.role === "helper") ? (
        <div className="border-b border-line pb-4">
          <TeamPanel
            requestId={requestId}
            team={team}
            controlsOnly
            mine={(() => {
              const me = team.find((m) => m.is_me);
              return me ? { role: me.role, status: me.status } : null;
            })()}
            onChanged={() => void load()}
          />
        </div>
      ) : null}

      {/* Where to drive. Above the conversation on purpose -- a helper opening this on the road
          wants the pin, not to scroll past twenty messages to find it.

          The coordinates are the ones request_thread returned, which are the ones the requester
          confirmed and the ones the matching ran against. Nothing is recomputed here, so there is
          no way for this card to disagree with the database about where somebody is. */}
      {location ? (
        <div className="space-y-2 rounded-field border-2 border-good bg-surface-sunk p-3">
          <h3 className="text-base font-semibold">{t("locationTitle")}</h3>

          <p className="font-mono text-base">
            {location.lat.toFixed(6)}, {location.lng.toFixed(6)}
          </p>

          {location.source ? (
            <p className="text-sm text-ink-soft">
              {/* Named, because "coordinates" covers both a pin dropped on satellite imagery and a
                  phone fix with 300m of error, and a volunteer deciding whether to trust it to the
                  metre should be told which. */}
              {LOCATION_SOURCES.has(location.source)
                ? t(`locationSource.${location.source}` as never)
                : location.source}
            </p>
          ) : null}

          {location.accuracy_m != null ? (
            <p className="text-sm text-ink-soft">
              {t("locationAccuracy", { value: `${Math.round(location.accuracy_m)} m` })}
            </p>
          ) : null}

          {location.note ? (
            <p className="text-base">{t("locationNote", { note: location.note })}</p>
          ) : null}

          {/* One link for every platform. A geo: URI is the "native" answer and iOS does not
              handle it, so this is the Google Maps directions URL, which Android hands to the
              Maps app, iOS hands to Maps or Safari, and a laptop opens in a tab. Six decimals,
              so the destination is the confirmed point rather than a rounded version of it. */}
          <a
            href={`https://www.google.com/maps/dir/?api=1&destination=${location.lat.toFixed(6)},${location.lng.toFixed(6)}`}
            target="_blank"
            rel="noopener noreferrer"
            className="tap-target flex w-full items-center justify-center rounded-field border-2 border-brand bg-brand px-4 text-center text-lg font-semibold text-white"
          >
            {t("locationOpen")}
          </a>

          <p className="text-xs text-ink-faint">{t("locationPrivate")}</p>
        </div>
      ) : null}

      {messages.length === 0 && pending.length === 0 ? (
        <p className="text-base text-ink-soft">{t("empty")}</p>
      ) : (
        <ul className="space-y-2">
          {messages.map((message) => (
            <li
              key={message.id}
              className={`max-w-[85%] rounded-field border-2 p-3 ${
                message.mine
                  ? "ml-auto border-brand bg-brand-tint"
                  : "mr-auto border-line bg-surface-sunk"
              }`}
            >
              {/* Who said it. Redundant with two people; necessary with a team, where "they" is
                  ambiguous and a system line belongs to nobody. */}
              {!message.mine && message.sender_name ? (
                <p className="text-xs font-semibold text-ink-soft">{message.sender_name}</p>
              ) : null}
              {message.body ? (
                <p className="whitespace-pre-wrap text-base">{message.body}</p>
              ) : null}
              <p className="mt-1 text-xs text-ink-faint">
                {relative(message.created_at)}
                {/* No read receipt. It used to read `read_at` on the message, which worked only
                    because there were exactly two people: "not mine and read" meant the other
                    one saw it. With a team that is meaningless -- seen by whom? -- so unread is
                    now tracked per participant and the per-message flag is gone. A group read
                    indicator is a separate piece of work, and showing a stale one would be worse
                    than showing none. */}
              </p>
            </li>
          ))}

          {/* Written by this member, not yet acknowledged by the server. Dashed and dimmed: it
              must not be mistakable for a message the team can see, because acting on "I told
              them" when nobody was told is the failure this whole queue exists to avoid. */}
          {pending.map((item) => (
            <li
              key={item.clientId}
              className="ml-auto max-w-[85%] rounded-field border-2 border-dashed border-line bg-surface-sunk p-3 opacity-70"
            >
              <p className="whitespace-pre-wrap text-base">{item.body}</p>
              <p className="mt-1 text-xs text-ink-faint">
                {item.attempts > 1 ? t("retrying", { attempts: item.attempts }) : t("waiting")}
              </p>
            </li>
          ))}
        </ul>
      )}

      {pending.length > 0 ? (
        <p className="text-sm text-ink-faint">
          {t("queuedCount", { count: pending.length })} — {t("waitingNote")}
        </p>
      ) : null}

      <div ref={endRef} />

      {closed || readOnly ? (
        <p className="text-sm text-ink-faint">{t("closedNote")}</p>
      ) : (
        <form onSubmit={submit} className="space-y-2">
          <TextArea
            aria-label={t("composeLabel")}
            placeholder={t("placeholder")}
            value={body}
            onChange={(e) => setBody(e.target.value)}
            maxLength={2000}
            rows={2}
          />
          <Button type="submit" disabled={busy || body.trim().length === 0}>
            {busy ? t("sending") : t("send")}
          </Button>
        </form>
      )}
    </Card>
  );
}
