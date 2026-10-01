import { expect, test, type Page } from "@playwright/test";

/**
 * The Events tab.
 *
 * The events feature itself is phase 12's and already has pgTAP coverage: the table, its
 * CHECKs, create_event, events_upcoming and RSVPs. What had never existed was a screen, which
 * is why CLAUDE.md said events were "deferred" when the backend had been there for a week.
 *
 * So this suite is about the screen, and specifically about the one thing that silently breaks
 * it: create_event defaults to status 'draft', and events_upcoming lists only 'published'. An
 * event posted without that flag disappears into a queue nothing in this app can show, and the
 * composer looks like it worked. The owner chose publish-immediately on 2026-10-01, and the
 * assertion below is what holds the UI to it.
 *
 * One project, like the other suites that write real rows.
 */

const WHO = { email: "mike@winchup.test", password: "recovery-demo-2026" };

test.describe.configure({ mode: "serial" });

test.beforeEach(({}, testInfo) => {
  test.skip(testInfo.project.name !== "android", "Writes real events: one project only");
});

async function signIn(page: Page) {
  await page.goto("/signin");

  // Hydration first: keystrokes delivered before React attaches are undone when it does,
  // leaving the form empty and the button disabled. Same wait as membership-agreement.spec.
  await page
    .locator("form")
    .first()
    .evaluate(
      (el) =>
        new Promise<void>((resolve) => {
          const attached = () => Object.keys(el).some((k) => k.startsWith("__react"));
          if (attached()) return resolve();
          const timer = setInterval(() => {
            if (attached()) {
              clearInterval(timer);
              resolve();
            }
          }, 50);
        }),
    );

  await page.getByLabel(/email|correo/i).pressSequentially(WHO.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(WHO.password);
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });
}

test("an event posted from the feed is published, and shows on the Events tab", async ({
  page,
}) => {
  await signIn(page);
  await page.goto("/community");

  await page.getByRole("tab", { name: /^events$|^eventos$/i }).click();

  // The post composer is not on this tab: it files something this tab cannot show.
  await expect(
    page.getByRole("button", { name: /^post$|^publicar$/i }),
    "the post composer is hidden on Events",
  ).toHaveCount(0);

  const title = `Trail day ${Date.now().toString(36)}`;

  await page.getByRole("button", { name: /post an event|publicar un evento/i }).click();
  await page.getByLabel(/what is it|qué es/i).pressSequentially(title);

  const when = new Date(Date.now() + 3 * 24 * 60 * 60 * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  await page
    .locator('input[type="datetime-local"]')
    .fill(`${when.getFullYear()}-${pad(when.getMonth() + 1)}-${pad(when.getDate())}T10:00`);

  await page
    .getByLabel(/where to meet|dónde encontrarse/i)
    .pressSequentially("Gravel lot at the crossing");

  await page.getByRole("button", { name: /post it|^publicar$/i }).click();

  // THE ASSERTION THAT MATTERS. events_upcoming returns published events only, so an event
  // appearing here proves the composer sent status: published. Without it the call still
  // succeeds and the event is never seen again.
  await expect(
    page.locator("li").filter({ hasText: title }).first(),
    "the event is visible immediately, so it was published rather than drafted",
  ).toBeVisible({ timeout: 20_000 });

  await expect(page.locator("li").filter({ hasText: title }).first()).toContainText(
    /gravel lot at the crossing/i,
  );

  // It survives a reload: it is a row, not optimistic state.
  await page.reload();
  await page.getByRole("tab", { name: /^events$|^eventos$/i }).click();
  await expect(page.locator("li").filter({ hasText: title }).first()).toBeVisible({
    timeout: 20_000,
  });
});

test("an event needs a title, a time and a meeting point", async ({ page }) => {
  await signIn(page);
  await page.goto("/community");

  await page.getByRole("tab", { name: /^events$|^eventos$/i }).click();
  await page.getByRole("button", { name: /post an event|publicar un evento/i }).click();

  const post = page.getByRole("button", { name: /post it|^publicar$/i });
  await expect(post, "nothing filled in: refused before it reaches the database").toBeDisabled();

  await page.getByLabel(/what is it|qué es/i).pressSequentially("Title only");
  await expect(post, "a title alone is not an event").toBeDisabled();
});
