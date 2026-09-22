import { expect, test } from "@playwright/test";

/**
 * The pages that need an account, checked the only way that works.
 *
 * This suite exists because of a specific mistake. `/request` and `/account` return HTTP 200 to
 * curl while a browser correctly lands on `/signin` — the guard runs after the head has flushed,
 * so the redirect arrives as a client navigation rather than a 307. I read that 200 as "the
 * guard is broken", swapped a working redirect for a different implementation, and wrote the
 * false claim into a code comment before a browser showed me otherwise.
 *
 * A status code is not the behaviour. Where the person ends up is the behaviour.
 */

const GUARDED = [
  { path: "/request", why: "the request wizard needs an account to attach the request to" },
  { path: "/account", why: "your own profile" },
  { path: "/account/vehicles", why: "your own rigs" },
];

test.describe("signed out", () => {
  for (const { path, why } of GUARDED) {
    test(`${path} sends you to sign in — ${why}`, async ({ page }) => {
      await page.goto(path);
      await page.waitForURL(/\/signin/, { timeout: 15_000 });

      // Not just the URL: the sign-in form has to actually be there.
      await expect(page.getByLabel(/email|correo/i)).toBeVisible();
      await expect(page.getByLabel(/password|contraseña/i)).toBeVisible();
    });
  }

  test("the guarded page's own content never renders on the way past", async ({ page }) => {
    await page.goto("/account");
    await page.waitForURL(/\/signin/, { timeout: 15_000 });

    const text = await page.locator("main").innerText();
    // "Delete your account" is only on the real account page. Seeing it would mean the page
    // rendered before redirecting, which is what the server-side check exists to prevent.
    expect(text).not.toMatch(/Delete your account|Eliminar su cuenta/i);
  });

  test("Spanish speakers are sent to the Spanish sign in", async ({ page }) => {
    await page.goto("/es/account");
    await page.waitForURL(/\/es\/signin/, { timeout: 15_000 });
    await expect(page.locator("main")).toContainText(/Iniciar sesión/i);
  });
});

test.describe("the sign in form itself", () => {
  test("will not submit an incomplete form", async ({ page }) => {
    await page.goto("/signin");

    const submit = page.getByRole("button", { name: /sign in|iniciar sesión/i });
    await expect(submit).toBeDisabled();

    await page.getByLabel(/email|correo/i).fill("someone@example.com");
    await expect(submit, "still disabled without a password").toBeDisabled();

    await page.getByLabel(/password|contraseña/i).fill("short");
    await expect(submit, "still disabled with a password under 8 characters").toBeDisabled();

    await page.getByLabel(/password|contraseña/i).fill("longenough123");
    await expect(submit, "enabled once both fields are valid").toBeEnabled();
  });

  test("offers the way out that people actually need", async ({ page }) => {
    await page.goto("/signin");
    await expect(page.getByRole("link", { name: /forgot|olvidó/i })).toBeVisible();
    await expect(page.getByRole("link", { name: /create an account|crear una cuenta/i })).toBeVisible();
  });
});
