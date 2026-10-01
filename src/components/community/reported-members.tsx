"use client";

import { useCallback, useEffect, useState } from "react";
import { useFormatter, useTranslations } from "next-intl";

import { Button, Callout, Card } from "@/components/ui/primitives";
import { Link } from "@/i18n/navigation";
import { supabaseBrowser } from "@/lib/supabase/client";

type Report = {
  report_id: string;
  user_id: string;
  display_name: string | null;
  reason: string;
  note: string | null;
  status: string;
  created_at: string;
  member_since: string | null;
  suspended_at: string | null;
  suspended_reason: string | null;
  reports_total: number;
};

/**
 * Reported members, and suspending one. Spec §6.
 *
 * WHO SEES WHAT, and why it is split. A moderator reads this queue and can open the profile; only an
 * admin gets the suspend button. CLAUDE.md is explicit that the moderator role stops short of
 * anything reaching a volunteer's phone number or the waiver, and suspending an account is a larger
 * action than hiding a post, not a smaller one -- it takes somebody out of the directory, off the
 * dispatch ring and out of reach of the community in one press.
 *
 * `isAdmin` decides what RENDERS and nothing else. admin_suspend_member() calls
 * app.require_admin(), which raises -- so a moderator who found the call some other way is refused
 * by the database. This prop exists so they are not shown a button that will only fail.
 *
 * REPORTS TOTAL is shown next to each one on purpose. A single report is one member's bad evening;
 * four reports from four people about the same member is the pattern that actually decides it, and a
 * queue of individual rows hides that unless it is counted.
 *
 * No phone, no email. Somebody deciding whether a member is abusive does not need their contact
 * details, and moderation_reported_members() does not return them.
 */
export function ReportedMembers({ isAdmin }: { isAdmin: boolean }) {
  const t = useTranslations("moderation.members");
  const tReason = useTranslations("memberProfile.safety.reason");
  const format = useFormatter();

  const [reports, setReports] = useState<Report[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);
  const [reason, setReason] = useState("");

  const load = useCallback(async () => {
    const { data, error } = await supabaseBrowser().rpc("moderation_reported_members", {});
    const result = data as { ok?: boolean; reports?: Report[] } | null;
    if (error || !result?.ok) {
      setFailed(true);
      setReports([]);
      return;
    }
    setFailed(false);
    setReports(result.reports ?? []);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function suspend(userId: string) {
    if (busy) return;
    setBusy(userId);

    const { data, error } = await supabaseBrowser().rpc("admin_suspend_member", {
      p_user_id: userId,
      p_reason: reason.trim(),
    });

    setBusy(null);
    const result = data as { ok?: boolean } | null;
    if (error || !result?.ok) {
      setFailed(true);
      return;
    }
    setConfirming(null);
    setReason("");
    await load();
  }

  async function restore(userId: string) {
    if (busy) return;
    setBusy(userId);
    const { error } = await supabaseBrowser().rpc("admin_restore_member", { p_user_id: userId });
    setBusy(null);
    if (error) {
      setFailed(true);
      return;
    }
    await load();
  }

  if (reports === null) {
    return <p className="py-6 text-base text-ink-soft">{t("loading")}</p>;
  }

  return (
    <section className="space-y-3">
      <h2 className="text-xl font-semibold text-ink">{t("title")}</h2>

      {failed ? <Callout tone="danger">{t("failed")}</Callout> : null}

      {reports.length === 0 ? (
        <p className="rounded-field border-2 border-line bg-surface-sunk p-4 text-base text-ink-soft">
          {t("empty")}
        </p>
      ) : (
        // A LIST, because it is one. Each member in their own li, which is what lets a reader --
        // and a test -- address one card rather than the whole section: with two people in the
        // queue, "the suspend button" is two buttons.
        <ul className="space-y-3">
          {reports.map((r) => (
            <li key={r.user_id}>
              <Card className="space-y-2">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                  <h3 className="text-lg font-bold text-ink">{r.display_name ?? t("someone")}</h3>
                  {r.suspended_at ? (
                    <span className="rounded-field bg-danger-tint px-3 py-1 text-sm font-bold text-danger">
                      {t("suspended")}
                    </span>
                  ) : null}
                </div>

                <p className="text-base text-ink">{tReason(r.reason as never)}</p>
                {r.note ? <p className="text-base text-ink-soft">{r.note}</p> : null}

                <p className="text-sm text-ink-faint">
                  {[
                    t("reportedWhen", { when: format.relativeTime(new Date(r.created_at)) }),
                    r.reports_total > 1 ? t("reportsTotal", { count: r.reports_total }) : null,
                    r.member_since
                      ? t("memberSince", {
                          when: format.dateTime(new Date(r.member_since), { dateStyle: "medium" }),
                        })
                      : null,
                  ]
                    .filter(Boolean)
                    .join(" · ")}
                </p>

                <p>
                  <Link
                    href={`/members/${r.user_id}`}
                    className="text-base underline underline-offset-4"
                  >
                    {t("openProfile")}
                  </Link>
                </p>

                {!isAdmin ? (
                  <p className="text-sm text-ink-faint">{t("adminOnly")}</p>
                ) : r.suspended_at ? (
                  <div className="space-y-2">
                    {r.suspended_reason ? (
                      <p className="text-sm text-ink-soft">
                        {t("suspendedFor", { reason: r.suspended_reason })}
                      </p>
                    ) : null}
                    <Button
                      size="md"
                      variant="secondary"
                      onClick={() => void restore(r.user_id)}
                      disabled={busy === r.user_id}
                    >
                      {busy === r.user_id ? t("working") : t("restore")}
                    </Button>
                  </div>
                ) : confirming === r.report_id ? (
                  <div className="space-y-2">
                    {/* A REASON IS REQUIRED, and the server refuses without one. Not paperwork: this is
                        what somebody reads in three months when the member asks why, or when a second
                        admin is deciding whether to lift it. */}
                    <label className="block space-y-1">
                      <span className="text-sm text-ink-soft">{t("reasonLabel")}</span>
                      <textarea
                        value={reason}
                        onChange={(e) => setReason(e.target.value)}
                        rows={2}
                        maxLength={500}
                        className="w-full rounded-field border-2 border-line bg-surface px-3 py-2 text-base text-ink"
                      />
                    </label>
                    <Callout tone="danger" className="text-sm">
                      {t("suspendWarning")}
                    </Callout>
                    <div className="flex flex-col gap-2 sm:flex-row">
                      <Button
                        size="md"
                        variant="danger"
                        onClick={() => void suspend(r.user_id)}
                        disabled={busy === r.user_id || reason.trim().length === 0}
                      >
                        {busy === r.user_id ? t("working") : t("suspendConfirm")}
                      </Button>
                      <Button size="md" variant="quiet" onClick={() => setConfirming(null)}>
                        {t("cancel")}
                      </Button>
                    </div>
                  </div>
                ) : (
                  <Button
                    size="md"
                    variant="secondary"
                    onClick={() => {
                      setConfirming(r.report_id);
                      setReason("");
                    }}
                  >
                    {t("suspend")}
                  </Button>
                )}
              </Card>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
