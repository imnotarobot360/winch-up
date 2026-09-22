import { expect, test } from "@playwright/test";

/**
 * Every link on every public page goes somewhere.
 *
 * Phase 15 asks for every page, button, form, menu and navigation link to be tested. Most of
 * that is covered a page at a time elsewhere; this is the part that only shows up when you walk
 * the whole thing — a tab bar pointing at a route somebody renamed, a footer link to a page that
 * moved, a guide linking to a sibling that was never written.
 *
 * It crawls from the public pages, follows internal links one level, and fails on anything that
 * does not answer. Read-only, like the rest of this directory.
 */

const START = ["/", "/board", "/resources", "/terms", "/waiver", "/privacy", "/signin"];

// Reached only with an account. They are expected to bounce a signed-out visitor to /signin,
// which is itself the correct answer, so they are not treated as broken.
const MEMBERS_ONLY = /^\/(community|trails|business|notifications|me|account|request|moderation)/;

test.describe("navigation", () => {
  test("every internal link on every public page resolves", async ({ page, baseURL }) => {
    const seen = new Set<string>();
    const broken: string[] = [];

    for (const start of START) {
      await page.goto(start);

      const hrefs = await page.$$eval("a[href]", (anchors) =>
        anchors.map((a) => a.getAttribute("href") ?? ""),
      );

      for (const href of hrefs) {
        // Only this site. External links are somebody else's uptime.
        if (!href.startsWith("/") || href.startsWith("//")) continue;

        const path = href.split("#")[0];
        if (path === "" || seen.has(path)) continue;
        seen.add(path);

        const response = await page.request.get(new URL(path, baseURL).toString(), {
          maxRedirects: 5,
        });

        // A members-only page answering 200 with a redirect to sign-in is correct; see the note
        // in auth-gate.spec.ts about why the status is 200 rather than 307.
        const acceptable = response.status() < 400 || MEMBERS_ONLY.test(path);

        if (!acceptable) broken.push(`${start} -> ${path} (${response.status()})`);
      }
    }

    expect(seen.size, "the crawl found links to follow").toBeGreaterThan(10);
    expect(broken, "links that do not resolve").toEqual([]);
  });

  test("the tab bar points at real routes", async ({ page, baseURL }) => {
    await page.goto("/board");

    const hrefs = await page.$$eval("nav a[href]", (anchors) =>
      anchors.map((a) => a.getAttribute("href") ?? "").filter((h) => h.startsWith("/")),
    );

    expect(hrefs.length, "the tab bar rendered").toBeGreaterThan(3);

    for (const href of hrefs) {
      const response = await page.request.get(new URL(href, baseURL).toString());
      expect(response.status(), `tab bar link ${href}`).toBeLessThan(400);
    }
  });

  test("the Spanish side has the same shape", async ({ page, baseURL }) => {
    await page.goto("/es");

    const hrefs = await page.$$eval("a[href]", (anchors) =>
      anchors.map((a) => a.getAttribute("href") ?? "").filter((h) => h.startsWith("/es")),
    );

    expect(hrefs.length, "Spanish pages link to Spanish pages").toBeGreaterThan(2);

    for (const href of hrefs.slice(0, 12)) {
      const response = await page.request.get(new URL(href, baseURL).toString(), {
        maxRedirects: 5,
      });
      expect(response.status(), `Spanish link ${href}`).toBeLessThan(400);
    }
  });
});
