/**
 * The three-dot progress from screen 5 of the design reference.
 *
 * The reference compresses the whole request into three steps. This wizard has eight, on the
 * documented rule that it is one question per screen because it is filled in by somebody stuck,
 * possibly panicking, on one bar of signal. Those eight are not being collapsed into three denser
 * forms to match a picture.
 *
 * What the reference is actually communicating is "there are three parts to this and you are in
 * the first" -- and that is true of the eight-step flow too, it was just never shown. So the eight
 * steps are grouped into the reference's three, and the dots track which group you are in. The
 * mockup's shape, the field-tested flow underneath.
 *
 * Groups, and why the boundaries fall where they do:
 *
 *   Location   the 911 gate and where you are. Everything needed to send somebody.
 *   Details    photos, vehicle, how stuck, what land. Everything that decides who to send.
 *   Review     name, number, waiver. Everything you have to agree to.
 */
const GROUPS = [
  { key: "location", steps: ["emergency", "location"] },
  { key: "details", steps: ["photos", "vehicle", "situation", "land"] },
  { key: "review", steps: ["contact", "consent"] },
] as const;

export type GroupKey = (typeof GROUPS)[number]["key"];

export function groupForStep(step: string): number {
  const i = GROUPS.findIndex((g) => (g.steps as readonly string[]).includes(step));
  return i === -1 ? 0 : i;
}

export function StepProgress({
  step,
  labels,
}: {
  step: string;
  /** One label per group, in order, already translated. */
  labels: string[];
}) {
  const active = groupForStep(step);

  return (
    <ol className="flex items-center gap-2" aria-label={labels.join(", ")}>
      {GROUPS.map((group, i) => {
        const done = i < active;
        const current = i === active;
        return (
          <li key={group.key} className="flex flex-1 items-center gap-2">
            <span
              // aria-current rather than a visual-only state: the dot is the only thing saying
              // where you are, and a screen reader user is filling in the same form.
              aria-current={current ? "step" : undefined}
              className={`flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-bold ${
                current
                  ? "bg-brand text-on-brand"
                  : done
                    ? "bg-good-tint text-good"
                    : "bg-surface-sunk text-ink-faint"
              }`}
            >
              {i + 1}
            </span>
            <span
              className={`truncate text-xs font-semibold ${
                current ? "text-ink" : "text-ink-faint"
              }`}
            >
              {labels[i]}
            </span>
          </li>
        );
      })}
    </ol>
  );
}
