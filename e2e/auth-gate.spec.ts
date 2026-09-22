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
  { path: "/community", why: "the feed is for members, not the public — /board is the public one" },
  { path: "/trails", why: "a page asserting a place is legal to drive on is not for strangers" },
  { path: "/business", why: "an advertiser's own campaigns and spend" },
  { path: "/notifications", why: "everything the app has told one particular person" },
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

  test("/moderation says what it is rather than redirecting", async ({ page }) => {
    // Not a redirect, because the queue is not somewhere a signed-out person was trying to get
    // to by accident. It says plainly what the screen is and offers the way in.
    await page.goto("/moderation");
    await expect(page.locator("main")).toContainText(/Sign in to open the moderation queue/i);

    // And nothing of the queue itself: no reported content, no filter tabs.
    const text = await page.locator("main").innerText();
    expect(text).not.toMatch(/Waiting|Acted on|Hide it/i);
  });

  test("the community feed's own content never renders on the way past", async ({ page }) => {
    await page.goto("/community");
    await page.waitForURL(/\/signin/, { timeout: 15_000 });

    const text = await page.locator("main").innerText();
    // The composer is only on the real feed. Seeing it would mean the page rendered before
    // redirecting — and a feed carries names and conversation, unlike /board.
    expect(text).not.toMatch(/No phone numbers and no links/i);
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

    // pressSequentially, not fill. On WebKit, Playwright's fill() on one field clears the other
    // one -- verified three ways against a real WebKit build: fill email then password leaves
    // email empty, fill password then email leaves password empty, and typing both works. It is
    // an automation artifact rather than something a person can hit, but a test that only passes
    // on Chromium is worth less than one that types like a person.
    await page.getByLabel(/email|correo/i).pressSequentially("someone@example.com");
    await expect(submit, "still disabled without a password").toBeDisabled();

    await page.getByLabel(/password|contraseña/i).pressSequentially("short");
    await expect(submit, "still disabled with a password under 8 characters").toBeDisabled();

    await page.getByLabel(/password|contraseña/i).pressSequentially("longenough123");
    await expect(submit, "enabled once both fields are valid").toBeEnabled();
  });

  test("offers the way out that people actually need", async ({ page }) => {
    await page.goto("/signin");
    await expect(page.getByRole("link", { name: /forgot|olvidó/i })).toBeVisible();
    await expect(page.getByRole("link", { name: /create an account|crear una cuenta/i })).toBeVisible();
  });
});
