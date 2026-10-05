import { describe, expect, it } from "vitest";

import { interpolate } from "./copy";

describe("interpolate", () => {
  it("fills a placeholder from the params the database already sends", () => {
    // The exact bug: this copy is push-enabled and reached lock screens as literal braces.
    expect(interpolate("{name} sent you a message", { name: "Rosa" })).toBe(
      "Rosa sent you a message",
    );
  });

  it("fills several placeholders, including numbers", () => {
    expect(
      interpolate("{miles} miles away — {vehicle} stuck in {stuck}.", {
        miles: 2.8,
        vehicle: "truck",
        stuck: "mud",
      }),
    ).toBe("2.8 miles away — truck stuck in mud.");
  });

  it("leaves copy with no placeholders untouched", () => {
    expect(interpolate("Somebody near you needs a hand.", { miles: 3 })).toBe(
      "Somebody near you needs a hand.",
    );
  });

  it("leaves the placeholder visible when the parameter is missing", () => {
    // Deliberate. Blanking it would read as a finished sentence, which is how the original bug
    // survived -- a notification that had lost its parameter looked like a design choice.
    expect(interpolate("{name} sent you a message", {})).toBe("{name} sent you a message");
  });

  it("treats null and empty string as missing rather than printing them", () => {
    expect(interpolate("{a}/{b}", { a: null, b: "" })).toBe("{a}/{b}");
  });

  it("survives params being null, which is what a notification with no params returns", () => {
    expect(interpolate("A volunteer is coming.", null)).toBe("A volunteer is coming.");
  });

  it("does not re-scan a substituted value for placeholders", () => {
    // A member can set their own display name. One pass means their name cannot expand into
    // anything else, however it is spelled.
    expect(interpolate("{name} sent you a message", { name: "{miles}", miles: 99 })).toBe(
      "{miles} sent you a message",
    );
  });

  it("ignores a placeholder whose key is not a word, so stray braces in copy are safe", () => {
    expect(interpolate("Saved {} and {a-b} and {}", { a: 1 })).toBe("Saved {} and {a-b} and {}");
  });

  it("renders zero, which is a real distance and must not be treated as missing", () => {
    // 0.0 miles happens: two members with the same home point. Falsy-checking would have printed
    // "{miles} miles away" to the one person standing closest to the recovery.
    expect(interpolate("{miles} miles away", { miles: 0 })).toBe("0 miles away");
  });
});
