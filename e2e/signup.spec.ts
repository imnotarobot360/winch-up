import { expect, test } from "@playwright/test";

/**
 * Signing up, in Spanish, all the way to a confirmed account.
 *
 * This exists for one link in the chain that nothing else could see. The welcome email is queued
 * by a database trigger long after the browser has gone, and the language it goes out in comes
 * from `raw_user_meta_data.locale` -- which is written exactly once, by auth-form.tsx, at the
 * moment of signup. Nothing verified that the form actually sends it. pgTAP proves the trigger
 * reads the column; it cannot prove anybody ever fills it in.
 *
 * It could not be tested before today either: the local auth shim had no /signup route at all, so
 * the real signup path 404'd and every suite signed in as a seeded account instead.
 *
 * WHAT THIS DOES NOT ASSERT
 *
 * The queued row itself. Playwright has no database connection here and adding one would put a
 * Postgres client in the test layer for a single assertion. The column and the trigger are
 * covered by supabase/tests/email_test.sql; what this covers is the browser half -- that a real
 * form submission on a real Spanish page produces an account the rest of that chain can work on.
 */

const PASSWORD = "recovery-demo-2026";

// The shim accepts one fixed code for everything, which is also the emailed-link stand-in.
const TEST_OTP = "123456";

test.describe.configure({ mode: "serial" });

test.beforeEach(({}, testInfo) => {
  test.skip(
    testInfo.project.name !== "android",
    "Creates a real account each run: one project only, like the other state-machine suites",
  );
});

test("a Spanish signup records the language, and confirming it signs you in", async ({ page, request }) => {
  // Unique per run. These accumulate in the local database the way the demo accounts do; the
  // rebuild script is what clears them out.
  const email = `signup-e2e-${Date.now()}@example.invalid`;

  // The Spanish page specifically. On /signup the locale would be "en" and the assertion that
  // matters -- that the form sends whatever language the member is actually reading -- would
  // pass whether or not the code did anything.
  await page.goto("/es/signup");

  await expect(page.getByRole("heading", { name: /cree su cuenta/i })).toBeVisible();

  // pressSequentially, not fill: on WebKit fill() on one field clears its sibling.
  await page.getByLabel(/correo electrónico/i).pressSequentially(email);
  await page.getByLabel(/contraseña/i).pressSequentially(PASSWORD);
  await page.getByRole("button", { name: /crear cuenta/i }).click();

  // Same answer whether or not the address was already taken -- that is deliberate, and the
  // reason this is the success condition rather than anything about the account.
  await expect(page.getByText(/revise su correo/i)).toBeVisible({ timeout: 15_000 });

  // A verification email that never arrives is a dead end -- the address can neither sign in nor
  // sign up again, because the account exists. The way out is on this screen.
  const resend = page.getByRole("button", { name: /enviar de nuevo/i });
  await expect(resend, "the resend control is offered").toBeVisible();

  await resend.click();

  // Replaced by a countdown, so the button is not a way to have us mail somebody repeatedly --
  // and whoever is clicking need not own the address.
  await expect(page.getByText(/enviado de nuevo/i)).toBeVisible({ timeout: 10_000 });
  await expect(page.getByText(/puede enviar otro en \d+ s/i)).toBeVisible();
  await expect(resend, "and the button is gone while the cooldown runs").toBeHidden();

  // Stand in for clicking the emailed link. Real Supabase exposes this as
  // verifyOtp({ email, token, type: 'signup' }), and the shim writes email_confirmed_at exactly
  // the way production does -- which is the transition the welcome-email trigger watches.
  const confirmed = await request.post(
    `${process.env.NEXT_PUBLIC_SUPABASE_URL ?? "http://127.0.0.1:54321"}/auth/v1/verify`,
    { data: { email, token: TEST_OTP, type: "signup" } },
  );
  expect(confirmed.ok(), "the shim confirms the address").toBeTruthy();

  // And the account works: signing in with it lands somewhere signed-in rather than back on the
  // form. This is what proves the signup wrote a usable password hash, not just a row.
  await page.goto("/es/signin");
  await page.getByLabel(/correo electrónico/i).pressSequentially(email);
  await page.getByLabel(/contraseña/i).pressSequentially(PASSWORD);
  await page.getByRole("button", { name: /iniciar sesión/i }).click();

  await page.waitForURL((url) => !/\/signin/.test(url.pathname), { timeout: 20_000 });
  await expect(page).not.toHaveURL(/\/signin/);
});
