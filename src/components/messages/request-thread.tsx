"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { TeamPanel, type TeamMember } from "@/components/recovery/team-panel";
import { Button, Callout, Card, TextArea } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

type Message = {
  id: string;
  sender_role: "requester" | "responder" | "admin" | "system";
  body: string | null;
  attachment_path: string | null;
  attachment_type: string | null;
  /** A first name. Null for a system line, which belongs to nobody. */
  sender_name: string | null;
  created_at: string;
  mine: boolean;
};

const POLL_MS = 15_000;

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
 * Polling rather than realtime. Fifteen seconds is well inside the rhythm of "I'm at the gate" /
 * "be there in twenty", and it costs one request instead of a websocket held open on a phone
 * with one bar of signal.
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
  const endRef = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    const { data, error: rpcError } = await supabaseBrowser().rpc("request_thread", {
      p_request_id: requestId,
    });

    if (rpcError) {
      // Signed out, or the session expired. Not a participant either way.
      setMessages(null);
      return;
    }

    const result = data as {
      ok: boolean;
      messages?: Message[];
      team?: (TeamMember & { is_me?: boolean })[];
      read_only?: boolean;
    };

    setMessages(result.ok ? (result.messages ?? []) : null);
    setTeam(result.ok ? (result.team ?? []) : []);
    setReadOnly(Boolean(result.read_only));
  }, [requestId]);

  useEffect(() => {
    void load();
    const timer = setInterval(() => void load(), POLL_MS);
    return () => clearInterval(timer);
  }, [load]);

  useEffect(() => {
    endRef.current?.scrollIntoView({ block: "nearest" });
  }, [messages?.length]);

  async function send(event: React.FormEvent) {
    event.preventDefault();
    const text = body.trim();
    if (!text || busy) return;

    setBusy(true);
    setError(null);

    const { data, error: rpcError } = await supabaseBrowser().rpc("send_request_message", {
      p_payload: { request_id: requestId, body: text },
    });

    setBusy(false);

    const result = data as { ok: boolean; error?: string } | null;

    if (rpcError || !result?.ok) {
      setError(result?.error ?? "failed");
      return;
    }

    setBody("");
    await load();
  }

  // Not a participant, or signed out. Render nothing at all.
  if (messages === null) return null;

  return (
    <Card className="space-y-3">
      <div>
        <h2 className="text-xl font-semibold">{t("title")}</h2>
        <p className="mt-1 text-sm text-ink-faint">{t("privateNote")}</p>
      </div>

      {error ? <Callout tone="danger">{t(`errors.${error}`)}</Callout> : null}

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

      {messages.length === 0 ? (
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
        </ul>
      )}

      <div ref={endRef} />

      {closed || readOnly ? (
        <p className="text-sm text-ink-faint">{t("closedNote")}</p>
      ) : (
        <form onSubmit={send} className="space-y-2">
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
