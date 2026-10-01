"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";

import { Button, Callout } from "@/components/ui/primitives";
import { supabaseBrowser } from "@/lib/supabase/client";

const REASONS = [
  "harassment",
  "impersonation",
  "spam",
  "soliciting_payment",
  "unsafe_advice",
  "other",
] as const;

/**
 * Report this member, or block them. Spec §6.
 *
 * TWO BUTTONS, NOT ONE, and deliberately not one that does both. A report asks an admin to look at
 * somebody; a block is a decision this member makes for themselves about who they will see. Quietly
 * blocking when asked to report takes that choice away, and quietly reporting when asked to block
 * puts a stranger in front of a moderator because somebody wanted a quieter feed. The server keeps
 * them separate too -- report_member() writes no block row, and there is a pgTAP assertion on it.
 *
 * Blocking reloads the page rather than updating in place. It changes what this member may see:
 * after a block the profile is not readable at all, because app.member_is_listable refuses in both
 * directions. The honest result of blocking somebody from their own profile page is to be sent back
 * to the directory without them in it, and anything cleverer would be pretending the page still has
 * something to show.
 *
 * The report form stays on the page and says what happened, because nothing visible changes and a
 * silent button leaves somebody pressing it again.
 */
export function MemberActions({ userId, name }: { userId: string; name: string }) {
  const t = useTranslations("memberProfile.safety");

  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState<(typeof REASONS)[number]>("harassment");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<"reported" | null>(null);
  const [failed, setFailed] = useState(false);

  async function report() {
    if (busy) return;
    setBusy(true);
    setFailed(false);

    const { data, error } = await supabaseBrowser().rpc("report_member", {
      p_user_id: userId,
      p_reason: reason,
      p_note: note.trim() || null,
    });

    setBusy(false);
    const result = data as { ok?: boolean } | null;
    if (error || !result?.ok) {
      setFailed(true);
      return;
    }
    // already_open is deliberately not distinguished. Somebody who reports the same person twice
    // wants to know it was received, and "you already reported them" reads like a refusal.
    setDone("reported");
    setOpen(false);
  }

  async function block() {
    if (busy) return;
    setBusy(true);
    setFailed(false);

    const { error } = await supabaseBrowser().rpc("community_block", {
      p_user_id: userId,
      p_on: true,
    });

    if (error) {
      setBusy(false);
      setFailed(true);
      return;
    }
    // A full navigation, not a router refresh: this page is about to become unreadable.
    window.location.assign("/members");
  }

  if (done === "reported") {
    return (
      <Callout tone="good" className="mt-6">
        {t("reportedBody")}
      </Callout>
    );
  }

  return (
    <section className="mt-8 space-y-3 border-t-2 border-line pt-5">
      {failed ? <Callout tone="danger">{t("failed")}</Callout> : null}

      {open ? (
        <div className="space-y-3 rounded-field border-2 border-line bg-surface-sunk p-4">
          <h2 className="text-lg font-semibold text-ink">{t("reportTitle", { name })}</h2>

          <fieldset className="space-y-2">
            <legend className="text-sm text-ink-soft">{t("reasonLegend")}</legend>
            {REASONS.map((r) => (
              <label key={r} className="flex items-center gap-3 text-base text-ink">
                <input
                  type="radio"
                  name="report-reason"
                  value={r}
                  checked={reason === r}
                  onChange={() => setReason(r)}
                  className="size-5"
                />
                {t(`reason.${r}` as never)}
              </label>
            ))}
          </fieldset>

          <label className="block space-y-1">
            <span className="text-sm text-ink-soft">{t("noteLabel")}</span>
            <textarea
              value={note}
              onChange={(e) => setNote(e.target.value)}
              rows={3}
              maxLength={1000}
              className="w-full rounded-field border-2 border-line bg-surface px-3 py-2 text-base text-ink"
            />
          </label>

          <div className="flex flex-col gap-2 sm:flex-row">
            <Button size="md" onClick={() => void report()} disabled={busy}>
              {busy ? t("working") : t("sendReport")}
            </Button>
            <Button size="md" variant="quiet" onClick={() => setOpen(false)} disabled={busy}>
              {t("cancel")}
            </Button>
          </div>
        </div>
      ) : (
        <div className="flex flex-col gap-2 sm:flex-row">
          <Button size="md" variant="secondary" onClick={() => setOpen(true)}>
            {t("report")}
          </Button>
          <Button size="md" variant="quiet" onClick={() => void block()} disabled={busy}>
            {t("block")}
          </Button>
        </div>
      )}

      <p className="text-sm text-ink-faint">{t("explainer")}</p>
    </section>
  );
}
