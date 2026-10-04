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
  // A crawl is about a returning visitor. Since 2026-09-27 a first-time signed-out visitor to /
  // or /es is sent to the onboarding screen, and that redirect arrives as a client navigation --
  // which destroys the execution context underneath `$$eval` and fails with something that
  // reads like a Playwright bug rather than a redirect. Seeding the cookie puts the crawl in the
  // state it is actually describing. The onboarding path itself is covered in public-pages.spec.
  test.beforeEach(async ({ context, baseURL }) => {
    await context.addCookies([
      {
        name: "wu_seen_welcome",
        value: "1",
        url: baseURL ?? "http://127.0.0.1:3000",
      },
    ]);
  });

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

        // ONE RETRY, AND ONLY FOR A TRANSPORT FAILURE.
        //
        // `next start` resets a connection now and then under a crawl this rapid -- the error is
        // `apiRequestContext.get: socket hang up`, it lands on a different unrelated static page
        // each time (/trails, /es/trails, /resources/etiquette), and it passes when this spec runs
        // alone. CLAUDE.md records the same thing for this spec and public-pages.spec.
        //
        // Letting it throw conflates two different claims. This test is about whether a LINK
        // RESOLVES; a dropped socket says nothing about that, and failing on it reports a broken
        // link that is not broken. So a connection error gets one more attempt.
        //
        // It is not swallowed: a second failure goes into `broken` like any other, so a genuinely
        // dead server still fails the test, and says it was the transport rather than a 404.
        const url = new URL(path, baseURL).toString();
        let response;
        try {
          response = await page.request.get(url, { maxRedirects: 5 });
        } catch {
          await page.waitForTimeout(500);
          try {
            response = await page.request.get(url, { maxRedirects: 5 });
          } catch (again) {
            broken.push(`${start} -> ${path} (transport: ${(again as Error).message})`);
            continue;
          }
        }

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

/**
 * /notifications is reachable when there is nothing unread.
 *
 * The crawl above cannot see this one. It runs signed out, and everything under MEMBERS_ONLY is
 * allowed to bounce to /signin -- so a members-only page with no route into it at all still
 * passes, which is exactly what happened.
 *
 * The header bell was the ONLY link to /notifications anywhere in the app, and it rendered null
 * whenever the unread count was zero. So the way in appeared when something arrived and vanished
 * the moment it was read, and notification history could not be opened again by any means.
 *
 * IT HAS TO OBSERVE THE ZERO-UNREAD CASE, and that is the whole difficulty.
 *
 * The first version of this test signed in as rosa and looked for the link. It passed with the
 * bug deliberately put back, because rosa has 248 unread notifications from the other suites, so
 * the bell rendered for the wrong reason entirely. A test of this that does not reach zero is
 * testing the badge.
 *
 * Marking everything read through the UI did not work either. So it uses the one account the
 * other suites do not generate notifications for, and ASSERTS THE BADGE IS ABSENT before
 * asserting the link is present. That ordering is the point: if this account ever starts
 * receiving notifications, the badge assertion fails and says so, rather than the test quietly
 * going green for the same wrong reason a second time.
 */
test.describe("the notifications entry point", () => {
  test("the header reaches /notifications with nothing unread", async ({ page }) => {
    await page.goto("/signin");
    // pressSequentially, not fill: on WebKit fill() on one field clears its sibling.
    await page.getByLabel(/email|correo/i).pressSequentially("admin@winchup.test");
    await page.getByLabel(/password|contraseña/i).pressSequentially("recovery-demo-2026");
    // Wait for it to ENABLE first. The button is disabled until the form validates the
    // typed values, and on a cold compile the click can land before React has registered
    // them -- which times out against a disabled button and reads as a broken sign-in.
    const submit = page.getByRole("button", { name: /^sign in$|^entrar$/i });
    await expect(submit).toBeEnabled({ timeout: 20_000 });
    await submit.click();
    await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });

    await page.goto("/");

    const bell = page.locator('a[href$="/notifications"]');
    await expect(bell).toBeVisible({ timeout: 20_000 });

    // The precondition, checked rather than assumed. The bell's accessible name carries the
    // count when there is one, so this is what "nothing unread" looks like from outside.
    await expect(bell).toHaveAccessibleName(/^(notifications|notificaciones)$/i);

    await bell.click();
    await expect(page).toHaveURL(/\/notifications$/);
    await expect(page.getByRole("heading", { name: /notifications|notificaciones/i }))
      .toBeVisible();
  });
});


/**
 * /account is reachable from the app, for a member with NO responder profile.
 *
 * It was reachable from nothing. Only from its own sub-pages, a notification deep link, and the
 * waiver decline path -- so a member could not find their settings, their rigs, their
 * notification preferences, or the button that deletes their account. Same failure as /welcome:
 * every page rendered, every link resolved, and the route in did not exist.
 *
 * The crawl above cannot catch it. It runs signed out, and /account is on MEMBERS_ONLY, which
 * is allowed to bounce to /signin -- so a members-only page with no route into it passes.
 *
 * NO RESPONDER PROFILE ON PURPOSE. The first fix put the link inside the profile card on /me,
 * which only renders for members who have one. admin@winchup.test does not, so it landed in the
 * other branch entirely and the link was still missing for exactly the people most likely to
 * want it. Using an account with a profile here would have passed and proved nothing.
 */
test.describe("account settings are reachable", () => {
  test("a member with no responder profile can reach /account from /me", async ({ page }) => {
    await page.goto("/signin");
    // pressSequentially, not fill: on WebKit fill() on one field clears its sibling.
    await page.getByLabel(/email|correo/i).pressSequentially("admin@winchup.test");
    await page.getByLabel(/password|contraseña/i).pressSequentially("recovery-demo-2026");
    // Wait for it to ENABLE first. The button is disabled until the form validates the
    // typed values, and on a cold compile the click can land before React has registered
    // them -- which times out against a disabled button and reads as a broken sign-in.
    const submit = page.getByRole("button", { name: /^sign in$|^entrar$/i });
    await expect(submit).toBeEnabled({ timeout: 20_000 });
    await submit.click();
    await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });

    await page.goto("/me");

    // The precondition: this really is the no-profile branch. If this account ever gains a
    // responder profile the assertion fails and says so, rather than the test passing for the
    // wrong reason from the profile card instead.
    await expect(page.getByRole("link", { name: /confirm my number|confirmar mi/i }))
      .toBeVisible({ timeout: 20_000 });

    const settings = page.getByRole("link", { name: /account settings|configuración de la cuenta/i });
    await expect(settings).toBeVisible();

    await settings.click();
    await expect(page).toHaveURL(/\/account$/);

    // And the thing the route exists for: deleting your account.
    await expect(page.getByText(/delete your account|eliminar su cuenta/i).first()).toBeVisible();
  });
});
