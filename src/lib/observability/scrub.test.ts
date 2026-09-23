import { describe, expect, it } from "vitest";

import { REDACTED, scrubDeep, scrubText, scrubUrl } from "./scrub";

/**
 * These are the strings that must never reach an error tracker.
 *
 * Written as the real thing rather than as abstractions, because the failure this guards against
 * is somebody's phone number sitting in a dashboard, and a test that says `expect(scrub("x"))`
 * does not make anybody check twice.
 */

describe("what must never leave", () => {
  it("removes a phone number in every shape this app has ever stored one", () => {
    for (const phone of [
      "+15125550123",
      "15125550123",
      "512-555-0123",
      "(512) 555-0123",
      "512.555.0123",
      "5125550123",
    ]) {
      const scrubbed = scrubText(`failed to text ${phone} about TX-AB12`);
      expect(scrubbed, `${phone} survived`).not.toContain("5550123");
      expect(scrubbed).toContain(REDACTED);
    }
  });

  it("removes coordinates precise enough to drive to", () => {
    const scrubbed = scrubText("no responders near 30.2672,-97.7431");
    expect(scrubbed).not.toContain("30.2672");
    expect(scrubbed).not.toContain("97.7431");
  });

  it("leaves imprecise numbers alone, so the message still says something", () => {
    // Two decimal places is about a kilometre: a county, not a vehicle. And a radius, a count
    // or a duration has to survive or the report is useless.
    expect(scrubText("ring 2 at 30.27 covered 15 miles in 7 minutes")).toBe(
      "ring 2 at 30.27 covered 15 miles in 7 minutes",
    );
  });

  it("removes an email address", () => {
    expect(scrubText("no account for dana@example.com")).toBe(`no account for ${REDACTED}`);
  });

  it("removes anything shaped like a key or a token", () => {
    expect(scrubText("used eyJhbGciOiJIUzI1NiIsInR5cCI6")).toContain(REDACTED);
    expect(scrubText("apikey sb_publishable_abcdefghij")).toContain(REDACTED);
  });

  it("removes a long run of digits even when it is not formatted like anything", () => {
    expect(scrubText("id 98765432109876")).toBe(`id ${REDACTED}`);
  });
});

describe("urls", () => {
  it("removes a recovery status token, which is the key to a live recovery", () => {
    expect(scrubUrl("https://www.winch-up.com/r/demo-accepted-token-cccccc")).toBe(
      "https://www.winch-up.com/r/[token]",
    );
  });

  it("keeps the shape of a route so the report still says where it broke", () => {
    expect(scrubUrl("/es/trails/river-crossing")).toBe("/es/trails/[slug]");
    expect(scrubUrl("/post/9f8e7d6c")).toBe("/post/[id]");
  });

  it("drops the query string whole rather than filtering it", () => {
    // A denylist of parameter names is a promise about every parameter anybody adds later.
    expect(scrubUrl("/board?phone=5125550123&next=/me")).toBe("/board");
  });

  it("drops the fragment too", () => {
    expect(scrubUrl("/resources/gear#always-in-the-truck")).toBe("/resources/[slug]");
  });
});

describe("a whole event", () => {
  it("scrubs strings however deep they are buried", () => {
    const event = {
      message: "could not reach +15125550123",
      breadcrumbs: [{ data: { url: "/r/abc123token", note: "at 30.26721,-97.74311" } }],
      extra: { nested: { deeper: { phone: "512-555-0123" } } },
    };

    const scrubbed = scrubDeep(event);
    const flat = JSON.stringify(scrubbed);

    expect(flat).not.toContain("5550123");
    expect(flat).not.toContain("abc123token");
    expect(flat).not.toContain("30.26721");
    expect(scrubbed.breadcrumbs[0].data.url).toBe("/r/[token]");
  });

  it("blanks headers and credentials by name, whatever they hold", () => {
    const scrubbed = scrubDeep({
      request: { cookie: "sb-auth=xyz", authorization: "Bearer abc", Password: "hunter22" },
    });

    expect(scrubbed.request.cookie).toBe(REDACTED);
    expect(scrubbed.request.authorization).toBe(REDACTED);
    expect(scrubbed.request.Password).toBe(REDACTED);
  });

  it("does not run away on a deeply nested object", () => {
    let deep: Record<string, unknown> = { phone: "5125550123" };
    for (let i = 0; i < 40; i += 1) deep = { child: deep };

    expect(() => scrubDeep(deep)).not.toThrow();
  });

  /**
   * The regression group. Every test above this point asked whether `scrubUrl` redacts a token,
   * and it always did — the leak was that almost nothing in a real event goes through `scrubUrl`.
   * These ask the question the wire asked: is the token gone, wherever it happens to be sitting?
   */
  it("redacts a status token in a plain error message, not only in a url field", () => {
    const scrubbed = scrubDeep({
      message: "dispatch failed for +15125550123 at 30.26721,-97.74311 — see /r/Xk3nQ7pLmT9vB2rW8dYz",
    });

    expect(scrubbed.message).not.toContain("Xk3nQ7pLmT9vB2rW8dYz");
    expect(scrubbed.message).toContain("/r/[token]");
    // and still says what broke
    expect(scrubbed.message).toContain("dispatch failed");
  });

  it("redacts a status token in a stack frame and a breadcrumb message", () => {
    const scrubbed = scrubDeep({
      exception: {
        values: [{ stacktrace: { frames: [{ filename: "/r/Xk3nQ7pLmT9vB2rW8dYz/page.js" }] } }],
      },
      breadcrumbs: [{ message: "fetch GET /r/Xk3nQ7pLmT9vB2rW8dYz/status 404" }],
    });

    expect(JSON.stringify(scrubbed)).not.toContain("Xk3nQ7pLmT9vB2rW8dYz");
  });

  it("stops a path rule at the end of the token rather than eating the sentence", () => {
    // `[^/?#]+` matches spaces. In a URL that never mattered; in prose it would have swallowed
    // everything after the token, including the part that says what went wrong.
    const scrubbed = scrubText("opening /r/Xk3nQ7pLmT9vB2rW8dYz raised a timeout after 7 minutes");

    expect(scrubbed).toBe("opening /r/[token] raised a timeout after 7 minutes");
  });

  it("redacts a token that contains a long digit run", () => {
    // Ordering guard: if the digit patterns ran first they would break the token into pieces the
    // path rule no longer matches, leaving most of it in place.
    const scrubbed = scrubText("see /r/aa1234567890bb for details");

    expect(scrubbed).toBe("see /r/[token] for details");
  });

  it("leaves the parts of an error that make it useful", () => {
    const scrubbed = scrubDeep({
      message: "advance_dispatch failed: ring 2 had no candidates",
      tags: { route: "/api/sms/drain", status: "500" },
    });

    expect(scrubbed.message).toBe("advance_dispatch failed: ring 2 had no candidates");
    expect(scrubbed.tags.route).toBe("/api/sms/drain");
  });
});
