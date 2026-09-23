"use client";

import { useState, useTransition } from "react";
import { useTranslations } from "next-intl";

import { setMyStatusAction, withdrawAction } from "@/app/actions/team";
import { Button, Callout } from "@/components/ui/primitives";

export type TeamMember = {
  role: "requester" | "helper";
  status: string;
  name: string | null;
  vehicle: string | null;
  equipment: string[] | null;
  joined_at: string;
};

/** The order a recovery actually moves through. Withdrawn is not offered here — leaving is. */
const STATUSES = ["preparing", "en_route", "on_site", "assisting", "finished"] as const;

/**
 * Who is coming (spec section 4).
 *
 * Shown to whoever holds the status link, which is deliberate and unchanged in spirit: the page
 * has always named the volunteer who took the job. What it carries is names, vehicles and kit —
 * enough to know a tractor is on the way as well as a winch — and no way to contact anybody. The
 * phone number is still released to exactly one person at exactly one moment, which is
 * acceptance, and that lives in the card above this one.
 *
 * `mine` is only passed when the viewer is signed in AND on the team, so the status control and
 * the leave button never render for a link-holder.
 */
export function TeamPanel({
  requestId,
  team,
  mine,
  onChanged,
  /**
   * Skip the roster and render only this member's own controls.
   *
   * The thread is embedded inside the status page, and both wanted to show the team — which put
   * the same list on screen twice, one above the other. The page owns the roster; the thread owns
   * the buttons that act on your own membership, because only participants can open it.
   */
  controlsOnly = false,
}: {
  requestId: string;
  team: TeamMember[];
  mine?: { role: "requester" | "helper"; status: string } | null;
  onChanged?: () => void;
  controlsOnly?: boolean;
}) {
  const t = useTranslations("team");
  const tEnum = useTranslations("enum");
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [confirmLeave, setConfirmLeave] = useState(false);

  if (team.length === 0) return null;

  const helpers = team.filter((m) => m.role === "helper");

  return (
    <div className="space-y-4">
      {controlsOnly ? null : (
        <div>
          <h2 className="text-xl font-bold">{t("title")}</h2>
          <p className="mt-1 text-base text-ink-soft">
            {t("count", { helpers: helpers.length })}
          </p>
        </div>
      )}

      {error ? (
        <Callout tone="danger" role="alert">
          {t(`errors.${error}` as never)}
        </Callout>
      ) : null}

      {controlsOnly ? null : (
      <ul className="space-y-2">
        {team.map((member, index) => (
          <li
            key={`${member.role}-${member.name ?? index}`}
            className="rounded-2xl border border-line p-3"
          >
            <div className="flex items-baseline justify-between gap-2">
              <span className="text-lg font-semibold">
                {member.name ?? t("someone")}
              </span>
              <span className="shrink-0 text-sm text-ink-soft">
                {member.role === "requester"
                  ? t("roleRequester")
                  : tEnum(`participantStatus.${member.status}` as never)}
              </span>
            </div>

            {member.vehicle ? (
              <p className="text-base text-ink-soft">{member.vehicle}</p>
            ) : null}

            {/* What they are bringing. The difference between a winch job and a tractor job is
                exactly this line, and it is why the panel lists kit rather than just names. */}
            {member.equipment && member.equipment.length > 0 ? (
              <p className="mt-1 text-sm text-ink-faint">
                {member.equipment
                  .map((e) => tEnum(`equipment.${e}` as never))
                  .join(" · ")}
              </p>
            ) : null}
          </li>
        ))}
      </ul>
      )}

      {mine?.role === "helper" ? (
        <div className={controlsOnly ? "space-y-3" : "space-y-3 border-t border-line pt-4"}>
          <p className="text-base font-semibold">{t("yourStatus")}</p>

          <div className="grid grid-cols-2 gap-2">
            {STATUSES.map((status) => (
              <Button
                key={status}
                size="md"
                variant={mine.status === status ? "primary" : "secondary"}
                disabled={pending}
                onClick={() =>
                  startTransition(async () => {
                    setError(null);
                    const result = await setMyStatusAction(requestId, status);
                    if (!result.ok) setError(result.error);
                    else onChanged?.();
                  })
                }
              >
                {tEnum(`participantStatus.${status}` as never)}
              </Button>
            ))}
          </div>

          {/* Leaving is deliberately easy to do and hard to do by accident. Easy, because the
              alternative is a volunteer who never arrives and never says why, and the person in
              the ditch waits. Confirmed, because it tells everyone and hands on the lead. */}
          {confirmLeave ? (
            <div className="space-y-2">
              <Callout tone="danger">{t("leaveConfirm")}</Callout>
              <div className="flex gap-2">
                <Button
                  size="md"
                  variant="danger"
                  disabled={pending}
                  onClick={() =>
                    startTransition(async () => {
                      setError(null);
                      const result = await withdrawAction(requestId);
                      if (!result.ok) setError(result.error);
                      else onChanged?.();
                    })
                  }
                >
                  {t("leaveYes")}
                </Button>
                <Button size="md" variant="secondary" onClick={() => setConfirmLeave(false)}>
                  {t("leaveNo")}
                </Button>
              </div>
            </div>
          ) : (
            <Button size="md" variant="quiet" onClick={() => setConfirmLeave(true)}>
              {t("leave")}
            </Button>
          )}
        </div>
      ) : null}
    </div>
  );
}
