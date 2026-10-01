"use client";

import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";

import { Button } from "@/components/ui/primitives";
import { useRouter } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * The Message button the design reference has always had.
 *
 * IT ASKS THE SERVER WHETHER IT SHOULD EXIST. dm_can_message() answers the same question dm_send() will
 * answer, from the same predicate, so the two cannot disagree -- a button that opens a composer which
 * then refuses is worse than no button, and this product has already shipped one of those (a Message
 * button in the reference that opened nothing was the reason the profile said "there is no direct
 * messaging here" instead).
 *
 * Three states, all of them honest:
 *
 *   can_message, no thread    -> "Send a message", opens a composer
 *   can_message, thread exists -> "Open the conversation", goes straight there
 *   cannot                     -> says why when the reason is the member's own choice
 *                                 (messages off), and says nothing at all when the reason is
 *                                 blocking or suspension
 *
 * That last distinction is the point. "They have messages turned off" is useful and reveals only a
 * preference. "You blocked them" or "they are suspended" would announce a moderation decision, and
 * telling somebody they were blocked is how blocking becomes an invitation to make another account --
 * so the server returns the same not_found for both and the button simply is not drawn.
 *
 * Rendered as nothing until the answer arrives, rather than drawn-then-hidden. A Message button that
 * appears for a moment and vanishes is worse than one that was never there.
 */
export function MessageMember({ userId, name }: { userId: string; name: string }) {
  const t = useTranslations("dm");
  const router = useRouter();

  const [state, setState] = useState<"loading" | "can" | "open" | "off" | "no">("loading");
  const [threadId, setThreadId] = useState<string | null>(null);
  const [composing, setComposing] = useState(false);
  const [body, setBody] = useState("");
  const [sending, setSending] = useState(false);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let alive = true;
    (async () => {
      const { data, error } = await supabaseBrowser().rpc("dm_can_message", {
        p_user_id: userId,
      });
      if (!alive) return;

      const result = data as
        | { ok?: boolean; can_message?: boolean; reason?: string; thread_id?: string }
        | null;

      // A failure here means no button, not a broken profile. The rest of the page is the point.
      if (error || !result?.ok) {
        setState("no");
        return;
      }
      if (result.can_message && result.thread_id) {
        setThreadId(result.thread_id);
        setState("open");
      } else if (result.can_message) {
        setState("can");
      } else {
        setState(result.reason === "messages_off" ? "off" : "no");
      }
    })();
    return () => {
      alive = false;
    };
  }, [userId]);

  async function send() {
    const text = body.trim();
    if (!text || sending) return;

    setSending(true);
    setFailed(false);

    const { data, error } = await supabaseBrowser().rpc("dm_send", {
      p_to_user_id: userId,
      p_body: text,
      p_client_id: crypto.randomUUID(),
    });

    setSending(false);
    const result = data as { ok?: boolean; thread_id?: string } | null;

    if (error || !result?.ok || !result.thread_id) {
      setFailed(true);
      return;
    }

    // Straight into the conversation. The first message is not worth a confirmation screen, and the
    // thread is the confirmation.
    router.push(`/messages/${result.thread_id}`);
  }

  if (state === "loading" || state === "no") return null;

  if (state === "off") {
    return <p className="mt-6 text-sm text-ink-faint">{t("theirMessagesOff", { name })}</p>;
  }

  if (state === "open" && threadId) {
    return (
      <div className="mt-6">
        <Button size="md" variant="secondary" onClick={() => router.push(`/messages/${threadId}`)}>
          {t("openConversation")}
        </Button>
      </div>
    );
  }

  if (!composing) {
    return (
      <div className="mt-6">
        <Button size="md" onClick={() => setComposing(true)}>
          {t("messageMember", { name })}
        </Button>
      </div>
    );
  }

  return (
    <form
      className="mt-6 space-y-2 rounded-field border-2 border-line bg-surface-sunk p-4"
      onSubmit={(e) => {
        e.preventDefault();
        void send();
      }}
    >
      <label className="block space-y-1">
        <span className="text-sm text-ink-soft">{t("firstMessageLabel", { name })}</span>
        <textarea
          value={body}
          onChange={(e) => setBody(e.target.value)}
          rows={3}
          maxLength={2000}
          className="w-full rounded-field border-2 border-line bg-surface px-3 py-2 text-base text-ink"
        />
      </label>

      {failed ? <p className="text-sm text-danger">{t("sendFailed")}</p> : null}

      <div className="flex flex-col gap-2 sm:flex-row">
        <Button type="submit" size="md" disabled={sending || body.trim().length === 0}>
          {sending ? t("sending") : t("send")}
        </Button>
        <Button size="md" variant="quiet" onClick={() => setComposing(false)} disabled={sending}>
          {t("cancel")}
        </Button>
      </div>
    </form>
  );
}
