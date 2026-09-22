"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useFormatter, useNow, useTranslations } from "next-intl";

import { Button, Callout, Card, TextArea } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

type Message = {
  id: string;
  sender_role: "requester" | "responder" | "admin" | "system";
  body: string | null;
  attachment_path: string | null;
  attachment_type: string | null;
  read_at: string | null;
  created_at: string;
  mine: boolean;
};

const POLL_MS = 15_000;

/**
 * The conversation between the person who is stuck and the volunteer who took the job.
 *
 * This component holds no permission logic at all. It asks request_thread() for the thread; if
 * the caller is not one of the two participants the RPC answers not_found and this renders
 * nothing. A signed-out visitor holding a shared status link therefore sees no trace of it --
 * not a locked panel, not a sign-in prompt, nothing. There is nothing to be curious about.
 *
 * Polling rather than realtime. Fifteen seconds is well inside the rhythm of "I'm at the gate" /
 * "be there in twenty", and it costs one request instead of a websocket held open on a phone
 * with one bar of signal.
 */
export function RequestThread({ requestId, closed }: { requestId: string; closed?: boolean }) {
  const t = useTranslations("thread");
  const format = useFormatter();
  const now = useNow({ updateInterval: 30_000 });

  const [messages, setMessages] = useState<Message[] | null>(null);
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

    const result = data as { ok: boolean; messages?: Message[] };
    setMessages(result.ok ? (result.messages ?? []) : null);
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
              {message.body ? (
                <p className="whitespace-pre-wrap text-base">{message.body}</p>
              ) : null}
              <p className="mt-1 text-xs text-ink-faint">
                {format.relativeTime(new Date(message.created_at), now)}
                {/* Only meaningful on your own messages: "they have seen it". */}
                {message.mine && message.read_at ? ` · ${t("read")}` : ""}
              </p>
            </li>
          ))}
        </ul>
      )}

      <div ref={endRef} />

      {closed ? (
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
