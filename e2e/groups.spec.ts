import { expect, test, type Page } from "@playwright/test";

/**
 * Groups.
 *
 * The tables and RPCs are phase 12's and have pgTAP coverage. What this covers is the screen
 * that reaches them, and above all that the screen IS REACHABLE: /members and /welcome and
 * /account were each built, deployed and then left linked from nothing, and every time it was
 * a person who noticed rather than a test. So the first assertion here starts on /community
 * and clicks through, rather than navigating straight to /groups.
 *
 * One project: it creates real groups.
 */

const WHO = { email: "mike@winchup.test", password: "recovery-demo-2026" };

test.describe.configure({ mode: "serial" });

test.beforeEach(({}, testInfo) => {
  test.skip(testInfo.project.name !== "android", "Creates real groups: one project only");
});

async function signIn(page: Page) {
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

  await page.getByLabel(/email|correo/i).pressSequentially(WHO.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(WHO.password);
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });
}

test("groups are reachable from the community screen, and one can be started", async ({
  page,
}) => {
  await signIn(page);

  // THE ROUTE IN, not a deep link. This is the assertion that would have caught /members.
  await page.goto("/community");
  await page.getByRole("link", { name: /groups|grupos/i }).click();
  await page.waitForURL(/\/groups/, { timeout: 20_000 });

  const name = `Creek County Crew ${Date.now().toString(36)}`;

  await page.getByRole("button", { name: /start a group|crear un grupo/i }).click();
  await page.getByLabel(/^name$|^nombre$/i).pressSequentially(name);
  await page.getByLabel(/^area$|^zona$/i).pressSequentially("Montgomery County");
  await page.getByRole("button", { name: /create it|crearlo/i }).click();

  const row = page.locator("li").filter({ hasText: name }).first();
  await expect(row, "the group appears in the list").toBeVisible({ timeout: 20_000 });

  // create_group makes the creator the owner, so the button says so rather than offering to
  // join something you already run.
  await expect(row).toContainText(/you started it|usted lo creó/i);
  await expect(
    row.getByRole("button", { name: /yours|suyo/i }),
    "an owner is not offered a Join button",
  ).toBeDisabled();

  // It is a row, not optimistic state.
  await page.reload();
  await expect(page.locator("li").filter({ hasText: name }).first()).toBeVisible({
    timeout: 20_000,
  });
});

test("a group needs a name before it can be created", async ({ page }) => {
  await signIn(page);
  await page.goto("/groups");

  await page.getByRole("button", { name: /start a group|crear un grupo/i }).click();

  await expect(
    page.getByRole("button", { name: /create it|crearlo/i }),
    "refused in the form rather than by the database",
  ).toBeDisabled();
});
