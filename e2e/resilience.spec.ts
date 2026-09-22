import { expect, test } from "@playwright/test";

/**
 * What the app does when something it depends on is not there.
 *
 * Phase 15 lists eleven error conditions. Four of them are about the world outside the database
 * — a denied GPS permission, a dead map provider, a dropped connection, a request that does not
 * exist — and a browser is the only instrument that can answer them. The rest are database
 * behaviour and live in supabase/tests/lifecycle_test.sql.
 *
 * These run against whatever Supabase the dev server points at, which is production, so like the
 * rest of this directory they are strictly read-only. Nothing here files a request.
 */

/**
 * NOT HERE: a denied GPS permission.
 *
 * The request wizard needs an account, so a signed-out visitor never reaches the step that asks
 * for a location -- they land on /signin, which is the correct behaviour and is covered in
 * auth-gate.spec.ts. Testing the denied-permission fallbacks needs a session, and this directory
 * is deliberately signed out and read-only because it runs against the production project.
 *
 * It belongs with the signed-in integration work. Saying so here is better than a test that
 * passes because it never got to the thing it claims to check.
 */

test.describe("when the map provider is down", () => {
  test("the page still works without it", async ({ page }) => {
    // Every Mapbox request fails, as it would if the token were wrong, the account suspended,
    // or the service having a bad morning.
    await page.route("**://*.mapbox.com/**", (route) => route.abort());
    await page.route("**://*.tiles.mapbox.com/**", (route) => route.abort());

    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));

    await page.goto("/board");

    await expect(page.locator("h1").first()).toBeVisible();
    await expect(page.locator("main")).toContainText(/board|tablero/i);

    // A dead tile server must not take the page with it. An uncaught exception here would mean
    // the list of open requests disappears because the picture beside it failed.
    expect(errors, "a dead map provider threw into the page").toEqual([]);
  });
});

test.describe("when the connection drops", () => {
  test("the offline page is served from the app itself, with no network at all", async ({
    page,
  }) => {
    // public/offline.html is what the service worker shows when nothing can be fetched. It has
    // no build step, no framework and no network calls, deliberately — so it is the one page
    // that has to work when everything else cannot.
    const response = await page.goto("/offline.html");
    expect(response?.status()).toBe(200);

    const text = await page.locator("body").innerText();
    expect(text.trim().length).toBeGreaterThan(20);

    // Both languages at once, because there is nobody to ask which one to use.
    expect(text).toMatch(/offline|connection|sin conexión|conexión/i);
  });

  test("nothing on the offline page needs the network", async ({ page }) => {
    const external: string[] = [];
    page.on("request", (request) => {
      const url = request.url();
      if (!url.includes("/offline.html") && !url.startsWith("data:")) external.push(url);
    });

    await page.goto("/offline.html");
    await page.waitForTimeout(500);

    expect(external, "the offline page asked the network for something").toEqual([]);
  });
});

test.describe("when a link points at nothing", () => {
  test("an unknown recovery token does not pretend to be a recovery", async ({ page }) => {
    await page.goto("/r/not-a-real-token-at-all");

    // Wait for the answer, not the shell. The status page resolves its token on the client, and
    // reading immediately catches an empty frame -- which on WebKit is eight characters of
    // header and looks exactly like a blank page bug.
    await expect(page.locator("main")).toContainText(/couldn't find|no encontramos/i, {
      timeout: 15_000,
    });

    const text = await page.locator("body").innerText();
    // No timeline, no volunteer name, no map — a wrong token is not a near miss.
    expect(text).not.toMatch(/Accepted by|Aceptado por|ETA|On site/i);
    expect(text.trim().length, "but it is still a page, not a blank screen").toBeGreaterThan(20);
  });
});
