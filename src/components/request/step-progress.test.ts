import { describe, expect, it } from "vitest";

import { groupForStep } from "./step-progress";

/**
 * The eight wizard steps map onto the reference's three dots.
 *
 * Worth testing because the mapping is the whole idea: the reference wanted three steps, the
 * wizard has eight for good reasons, and the dots are the reconciliation. If a step is added
 * later and nobody updates the grouping it silently falls into group one, and the progress
 * indicator starts lying about where somebody is in a form they are filling in while stuck.
 */

const STEPS = [
  "emergency",
  "location",
  "photos",
  "vehicle",
  "situation",
  "land",
  "contact",
  "consent",
] as const;

describe("which of the three groups a step belongs to", () => {
  it("puts the 911 gate and the location question in Location", () => {
    expect(groupForStep("emergency")).toBe(0);
    expect(groupForStep("location")).toBe(0);
  });

  it("puts everything that decides who to send in Details", () => {
    for (const step of ["photos", "vehicle", "situation", "land"]) {
      expect(groupForStep(step), step).toBe(1);
    }
  });

  it("puts what you have to agree to in Review", () => {
    expect(groupForStep("contact")).toBe(2);
    expect(groupForStep("consent")).toBe(2);
  });

  it("covers every step the wizard actually has", () => {
    // The guard against the real failure: a ninth step added without touching the grouping.
    // findIndex returns -1 for an unknown step and groupForStep turns that into 0, which is a
    // reasonable fallback and a terrible thing to rely on silently.
    const grouped = STEPS.map(groupForStep);
    expect(grouped).toEqual([0, 0, 1, 1, 1, 1, 2, 2]);
  });

  it("never goes backwards as the wizard advances", () => {
    // The dots only make sense if the group is monotonic in step order. Reordering STEPS without
    // reordering the groups would break that, and it would look like a glitch rather than a bug.
    const grouped = STEPS.map(groupForStep);
    for (let i = 1; i < grouped.length; i += 1) {
      expect(grouped[i], `${STEPS[i]} after ${STEPS[i - 1]}`).toBeGreaterThanOrEqual(grouped[i - 1]);
    }
  });

  it("falls back to the first group rather than throwing on something unknown", () => {
    expect(groupForStep("not-a-step")).toBe(0);
  });
});
