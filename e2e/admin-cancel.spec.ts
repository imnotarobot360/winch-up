import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * An admin closes a recovery from the queue.
 *
 * WHY THIS IS A BROWSER TEST AND NOT ONLY pgTAP. admin_cancel_test.sql already proves the RPC:
 * who may call it, that the dispatches are stood down, that the volunteer is texted, that the
 * audit row is written. None of that says the BUTTON works — and the button is the part that
 * failed for the owner on 2026-10-05, when they clicked Cancel in production and the request
 * stayed open. (It turned out they were on a bundle deployed a minute earlier, which did not have
 * the button in it. An hour of that would have been saved by this file existing.)
 *
 * So this asserts the whole path: an admin signs in, sees the control, clicks it, answers the
 * confirmation, and the request leaves the queue.
 *
 * THE CONFIRMATION IS PART OF THE FEATURE, not an obstacle to route around. A cancel is visible to
 * the person who asked for help and texts anyone already driving, and cannot be undone — so the
 * dialog is handled explicitly, and there is a case below that DISMISSES it and asserts nothing
 * happened. A confirm that does not actually guard is worse than none, because it buys confidence
 * it has not earned.
 */

const ADMIN = { email: "admin@winchup.test", password: "recovery-demo-2026" };

test.describe.configure({ mode: "serial" });

test.beforeEach(({}, testInfo) => {
  test.skip(
    testInfo.project.name !== "android",
    "Cancels a shared demo recovery: one project only",
  );
});

/** Keystrokes delivered before React attaches are undone when it does. Same wait as the other suites. */
async function hydrated(target: Locator) {
  await target.first().evaluate(
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

async function signIn(page: Page) {
  await page.goto("/signin");
  await hydrated(page.locator("form"));
  // pressSequentially, not fill: Playwright's fill() clears a sibling field on WebKit.
  await page.getByLabel(/email|correo/i).pressSequentially(ADMIN.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(ADMIN.password);
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });
}

/** The queue renders through useAdminData, so wait for a row rather than racing the fetch. */
async function openQueue(page: Page) {
  await page.goto("/admin");
  await expect(
    page.getByRole("button", { name: /^cancel$|^cancelar$/i }).first(),
    "the admin queue lists at least one open recovery with a cancel control",
  ).toBeVisible({ timeout: 30_000 });
}

test("the cancel control is on the queue at all", async ({ page }) => {
  await signIn(page);
  await openQueue(page);

  // The assertion that would have caught the production confusion: the button is SERVED, not just
  // written. A deploy that has not landed yet looks exactly like a feature that does not work.
  await expect(page.getByRole("button", { name: /^cancel$|^cancelar$/i }).first()).toBeEnabled();
});

test("dismissing the confirmation changes nothing", async ({ page }) => {
  await signIn(page);
  await openQueue(page);

  const before = await page.getByRole("button", { name: /^cancel$|^cancelar$/i }).count();

  // THE CONTROL FOR THE TEST BELOW. Without this, "clicking cancel closes the request" would also
  // pass against a button that closed it without ever asking.
  let asked = false;
  page.once("dialog", (dialog) => {
    asked = true;
    void dialog.dismiss();
  });

  await page.getByRole("button", { name: /^cancel$|^cancelar$/i }).first().click();
  await page.waitForTimeout(2000);

  expect(asked, "it asks before closing somebody's recovery").toBe(true);
  await expect(
    page.getByRole("button", { name: /^cancel$|^cancelar$/i }),
    "and saying no leaves every recovery exactly where it was",
  ).toHaveCount(before);
});

test("accepting it closes the recovery and drops it off the queue", async ({ page }) => {
  await signIn(page);
  await openQueue(page);

  const rows = page.getByRole("button", { name: /^cancel$|^cancelar$/i });
  const before = await rows.count();

  page.once("dialog", (dialog) => void dialog.accept());
  await rows.first().click();

  // The component reloads the queue after the action, so the row leaves on its own. Asserted by
  // the count dropping rather than by a toast: a toast proves the UI said something, and this has
  // to prove the recovery actually closed.
  await expect(
    rows,
    "one recovery has left the queue, so the RPC ran and the reload saw the new state",
  ).toHaveCount(before - 1, { timeout: 30_000 });

  // And it stays gone across a reload — the state is in the database, not in React.
  await page.reload();
  await page.waitForTimeout(1500);
  await expect(
    page.getByRole("button", { name: /^cancel$|^cancelar$/i }),
    "and it is still gone after a reload",
  ).toHaveCount(before - 1, { timeout: 30_000 });
});

test("the cancelled recovery is off the public board too", async ({ page }) => {
  // The whole reason an admin cancel exists: a request nobody can clear sits on the PUBLIC board.
  // Checked through the API rather than the page, because the board is what strangers see and the
  // page is just one renderer of it.
  const response = await page.request.get("/api/board");
  expect(response.ok(), "the public board responds").toBe(true);

  const body = (await response.json()) as
    | { short_code: string; status: string }[]
    | { requests?: { short_code: string; status: string }[] };
  const rows = Array.isArray(body) ? body : (body.requests ?? []);

  expect(
    rows.every((r) => r.status !== "cancelled"),
    "a cancelled recovery is never shown publicly",
  ).toBe(true);
});
