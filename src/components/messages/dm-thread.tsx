"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import { Avatar } from "@/components/ui/avatar";
import { Button, Callout } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

type Message = {
  id: string;
  body: string;
  mine: boolean;
  read_at: string | null;
  created_at: string;
};

type Other = {
  user_id: string;
  display_name: string | null;
  avatar_path: string | null;
  suspended: boolean;
};

/**
 * One direct conversation.
 *
 * POLLED, NOT LIVE, and that is a decision rather than a gap. The recovery thread has a Realtime
 * broadcast over a fifteen-second polling floor, authorised by a function in the `realtime` schema; a
 * direct message would need its own authorisation function, and the local stack has no realtime server
 * at all, so the socket path could not be tested here before shipping. CLAUDE.md is explicit that the
 * polling floor is the part that is not optional. A DM that arrives within fifteen seconds is a
 * conversation; a socket nobody has exercised is a feature that reports SUBSCRIBED and delivers nothing.
 *
 * THE CLIENT ID IS MINTED BEFORE THE FIRST ATTEMPT and reused by every retry of the same message. A
 * send that times out cannot tell the browser whether it landed, and both obvious answers are wrong --
 * give up and the member believes they said something they did not, retry blindly and the recipient
 * sees it twice. dm_messages_sender_client_idx makes the second row impossible, so retrying is free.
 *
 * Unlike the recovery thread there is no localStorage outbox. That exists for somebody standing in a
 * field with one bar who has to tell the volunteer which gate they are at, and it is keyed by request.
 * A social message that is lost when the tab closes costs nobody a recovery, and bending a tested module
 * to a different storage shape for this is not the trade. Named so the next person does not think it
 * was forgotten.
 */
const POLL_MS = 15_000;

export function DmThread({ threadId }: { threadId: string }) {
  const t = useTranslations("dm");
  const format = useFormatter();

  const [messages, setMessages] = useState<Message[] | null>(null);
  const [other, setOther] = useState<Other | null>(null);
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  const [failed, setFailed] = useState<null | "send" | "load" | "gone">(null);
  const [notFound, setNotFound] = useState(false);

  // Kept across retries of the SAME message, cleared only once the server has accepted it.
  const clientId = useRef<string | null>(null);
  const bottom = useRef<HTMLDivElement | null>(null);

  const load = useCallback(async () => {
    const { data, error } = await supabaseBrowser().rpc("dm_thread", { p_thread_id: threadId });
    const result = data as { ok?: boolean; error?: string; other?: Other; messages?: Message[] } | null;

    if (error) {
      setFailed("load");
      return;
    }
    if (!result?.ok) {
      // not_found covers "no such thread" and "not yours" alike, on purpose.
      setNotFound(true);
      return;
    }
    setFailed(null);
    setOther(result.other ?? null);
    setMessages(result.messages ?? []);
  }, [threadId]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    const timer = setInterval(() => void load(), POLL_MS);
    return () => clearInterval(timer);
  }, [load]);

  // Marking read is fire-and-forget: a failure means a badge stays up, which is not worth an error.
  useEffect(() => {
    void supabaseBrowser().rpc("dm_mark_read", { p_thread_id: threadId });
  }, [threadId, messages?.length]);

  useEffect(() => {
    bottom.current?.scrollIntoView({ block: "end" });
  }, [messages?.length]);

  async function send() {
    const body = draft.trim();
    if (!body || sending || !other) return;

    clientId.current ??= crypto.randomUUID();
    setSending(true);
    setFailed(null);

    const { data, error } = await supabaseBrowser().rpc("dm_send", {
      p_to_user_id: other.user_id,
      p_body: body,
      p_client_id: clientId.current,
    });

    setSending(false);
    const result = data as { ok?: boolean; error?: string } | null;

    if (error || !result?.ok) {
      // not_found here means they blocked you, were suspended, or deleted their account between
      // loading the thread and sending. Saying so plainly beats a generic failure the member would
      // retry forever.
      setFailed(result?.error === "not_found" ? "gone" : "send");
      return;
    }

    // Accepted. The next message needs its own key.
    clientId.current = null;
    setDraft("");
    await load();
  }

  if (notFound) {
    return (
      <Callout tone="neutral">
        <p>{t("threadGone")}</p>
        <p className="mt-2">
          <Link href="/messages" className="underline underline-offset-4">
            {t("backToInbox")}
          </Link>
        </p>
      </Callout>
    );
  }

  if (messages === null || other === null) {
    return <p className="py-8 text-center text-base text-ink-soft">{t("loading")}</p>;
  }

  return (
    // min-w-0: this is a flex item (the page is a flex column), and a flex item's default
    // min-width:auto lets a wide child push past the viewport rather than wrap. Without it the
    // message bubbles ran off the right edge on a phone -- which is the only screen that matters
    // here. Seen in a screenshot; the DOM text read fine, which is why it needed looking at.
    <div className="winch-panel w-full min-w-0 space-y-4 border border-line bg-surface-sunk p-4 sm:p-5">
      <header className="flex items-center gap-3 border-b border-line pb-4">
        <Avatar name={other.display_name} />
        <div className="min-w-0 flex-1">
          <Link
            href={`/members/${other.user_id}`}
            className="inline-flex min-h-11 items-center text-lg font-bold text-ink underline underline-offset-4"
          >
            {other.display_name ?? t("someone")}
          </Link>
          {other.suspended ? (
            <p className="text-sm text-ink-faint">{t("otherSuspended")}</p>
          ) : null}
        </div>
      </header>

      {failed === "load" ? <Callout tone="danger">{t("loadFailed")}</Callout> : null}
      {failed === "send" ? <Callout tone="danger">{t("sendFailed")}</Callout> : null}
      {failed === "gone" ? <Callout tone="neutral">{t("cannotReply")}</Callout> : null}

      {messages.length === 0 ? (
        <p className="py-6 text-center text-base text-ink-soft">{t("noMessagesYet")}</p>
      ) : (
        <ul className="space-y-3">
          {messages.map((m) => (
            <li
              key={m.id}
              className={m.mine ? "flex justify-end" : "flex justify-start"}
            >
              <div
                className={
                  m.mine
                    ? "winch-chat-bubble max-w-[85%] rounded-2xl rounded-br-sm bg-trail-soft px-4 py-3 text-ink"
                    : "winch-chat-bubble max-w-[85%] rounded-2xl rounded-bl-sm border border-line bg-surface px-4 py-3 text-ink"
                }
              >
                <p className="text-base whitespace-pre-wrap break-words">{m.body}</p>
                <p className="mt-2 text-xs text-ink-soft">
                  {format.relativeTime(new Date(m.created_at))}
                  {/* Read receipts only on your own messages: on theirs it would be telling them
                      what they already know, and read_at exists to answer "did they see it". */}
                  {m.mine && m.read_at ? ` · ${t("seen")}` : ""}
                </p>
              </div>
            </li>
          ))}
        </ul>
      )}

      <div ref={bottom} />

      {/* STACKED, not side by side. Button in this design system is unconditionally w-full --
          every other screen uses it that way -- so putting it in a flex row with the textarea
          squashed the input to a sliver and gave the button the rest. Vertical is also the right
          shape for a phone held one-handed, which is what this app is read on. */}
      <form
        className="winch-chat-composer space-y-2"
        onSubmit={(e) => {
          e.preventDefault();
          void send();
        }}
      >
        <textarea
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          rows={2}
          maxLength={2000}
          aria-label={t("composeLabel")}
          placeholder={t("composePlaceholder")}
          className="min-h-14 w-full resize-y rounded-field border border-line bg-surface px-3 py-3 text-base text-ink placeholder:text-ink-faint"
        />
        <Button type="submit" size="md" disabled={sending || draft.trim().length === 0}>
          {sending ? t("sending") : t("send")}
        </Button>
      </form>
    </div>
  );
}
