import { expect, test, type Page } from "@playwright/test";

/**
 * Blocking, and unblocking.
 *
 * Until 2026-10-01 the second half did not exist in the UI: community_block takes a boolean and
 * every call in the app passed true, while community_blocked_list had no caller. An accidental
 * block was permanent, because the only route back to somebody's posts is the thing blocking
 * them removes.
 *
 * This drives the round trip through the screens -- block from the feed, see them listed under
 * the account, unblock, see the list empty again -- because each half worked in isolation and
 * the pair is what was missing.
 *
 * Two accounts, one project.
 */

const ALICE = { email: "mike@winchup.test", password: "recovery-demo-2026" };
const BOB = { email: "rosa@winchup.test", password: "recovery-demo-2026" };

test.describe.configure({ mode: "serial" });

test.beforeEach(({}, testInfo) => {
  test.skip(testInfo.project.name !== "android", "Writes real blocks: one project only");
});

/**
 * Wait for React to attach before typing. Keystrokes delivered to a pre-hydration DOM are
 * undone when hydration replaces the inputs, which leaves the form empty and its submit button
 * disabled -- exactly how this spec failed first time, on the community composer rather than
 * on the sign-in form it was already guarded for.
 */
async function hydrated(page: Page) {
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
}

async function signIn(page: Page, who: { email: string; password: string }) {
  await page.goto("/signin");

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

  await page.getByLabel(/email|correo/i).pressSequentially(who.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(who.password);
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });
}

/**
 * Drop the session by clearing cookies rather than by pressing something.
 *
 * There is no plain "Sign out" control in this app -- the only one is "Sign out everywhere" on
 * /account/security, which revokes every refresh token on the account and is a heavier thing
 * than this test means. Driving a button that does not exist is how this spec failed twice.
 */
async function signOut(page: Page) {
  await page.context().clearCookies();
}

test("a block can be undone from the account screen", async ({ page }) => {
  // Bob posts, so Alice has something of his to block from.
  await signIn(page, BOB);
  await page.goto("/community");
  await hydrated(page);
  const marker = `blocked-spec-${Date.now().toString(36)}`;
  await page.locator("textarea").first().pressSequentially(`Gate is open again ${marker}`);
  await page.getByRole("button", { name: /^post$|^publicar$/i }).click();
  await expect(page.locator("li").filter({ hasText: marker }).first()).toBeVisible({
    timeout: 20_000,
  });

  await signOut(page);

  // Alice blocks him from the post's own menu.
  await signIn(page, ALICE);
  await page.goto("/community");
  await hydrated(page);

  const post = page.locator("li").filter({ hasText: marker }).first();
  await expect(post).toBeVisible({ timeout: 20_000 });
  await post.getByRole("button", { name: /more|más|options|opciones|⋯|…/i }).first().click();
  await page.getByRole("button", { name: /^block|bloquear/i }).first().click();

  // Gone from the feed.
  await expect(page.locator("li").filter({ hasText: marker })).toHaveCount(0, { timeout: 20_000 });

  // THE HALF THAT DID NOT EXIST: the list, and the way back.
  await page.goto("/account/blocked");
  const row = page.locator("li").first();
  await expect(row, "the blocked member is listed").toBeVisible({ timeout: 20_000 });

  await row.getByRole("button", { name: /unblock|desbloquear/i }).click();

  await expect(
    page.getByText(/have not blocked anybody|no ha bloqueado a nadie/i),
    "the list empties once the block is lifted",
  ).toBeVisible({ timeout: 20_000 });

  // And his posts come back, which is the thing a member actually wants to be true.
  await page.goto("/community");
  await expect(page.locator("li").filter({ hasText: marker }).first()).toBeVisible({
    timeout: 20_000,
  });
});
