import { execFileSync } from "node:child_process";
import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * A volunteer with no number on their VOLUNTEER PROFILE is told so, and told where to fix it.
 *
 * A PHONE LIVES IN TWO PLACES AND ONLY ONE OF THEM MAKES YOU TEXTABLE. /account/security adds a
 * number to the ACCOUNT (auth.users). The dispatcher reads responders.phone, which only the /join
 * form writes, through upsert_responder_profile. So a member can verify a number, watch the code
 * arrive, see the account screen confirm it, turn availability on — and never be texted, with
 * nothing anywhere saying why.
 *
 * That is not hypothetical. On 2026-10-05 the owner was the only volunteer on call in production,
 * had verified a phone, and the coverage report said "no number" for them. The text they had
 * received hours earlier was the Supabase Auth OTP — a different Twilio integration entirely —
 * which is what made it look as though call-out SMS was working when it had never once sent.
 *
 * The screen used to render one sentence for "you have not volunteered" and "we have no number
 * for you" alike, and that sentence said "add your number", which reads as something already done
 * to somebody who has just done it somewhere else.
 *
 * ONE PROJECT, because it edits a shared demo volunteer, and it puts the number back in teardown.
 */

const MIKE = { email: "mike@winchup.test", password: "recovery-demo-2026" };
const MIKE_USER = "00000000-0000-4000-8000-000000000002";

test.describe.configure({ mode: "serial" });

function psql(statement: string): string {
  return execFileSync(
    // Same resolution as rebuild.mjs and global-setup.ts: psql is NOT on PATH on the machine this
    // repo is developed on, so a bare "psql" throws spawnSync ENOENT inside beforeAll -- which
    // Playwright reports as ONE 0ms failure and then skips the rest of the file. Both specs written
    // on 2026-10-05 had this, and both were reported as passing earlier the same day, because they
    // happened to be run from a shell that had pgsql/bin on its PATH.
    process.env.PSQL ?? "psql",
    [
      "-h", "127.0.0.1",
      "-p", process.env.PGPORT ?? "55432",
      "-U", process.env.PGUSER ?? "postgres",
      "-d", process.env.PGDATABASE ?? "winchup",
      "-v", "ON_ERROR_STOP=1",
      "-tAc", statement,
    ],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, PGPASSWORD: process.env.PGPASSWORD ?? "postgres" },
    },
  ).trim();
}

/** Captured before anything is changed, so teardown restores the real value, not a guess. */
let originalPhone = "";

test.beforeAll(() => {
  originalPhone = psql(`select coalesce(phone, '') from public.responders where user_id = '${MIKE_USER}'`);
  if (!originalPhone) throw new Error("demo volunteer has no phone to begin with; nothing to test");
});

test.afterAll(() => {
  // Asserted-by-construction restore: every other suite drives this same account, and a volunteer
  // left without a number would quietly stop being textable in all of them.
  psql(`update public.responders set phone = '${originalPhone}' where user_id = '${MIKE_USER}'`);
});

test.beforeEach(({}, testInfo) => {
  test.skip(testInfo.project.name !== "android", "Edits a shared demo volunteer: one project only");
});

/** Keystrokes delivered before React attaches are undone when it does. */
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
  await page.getByLabel(/email|correo/i).pressSequentially(MIKE.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(MIKE.password);
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });
}

test("with a number, the member gets a real on/off switch", async ({ page }) => {
  psql(`update public.responders set phone = '${originalPhone}' where user_id = '${MIKE_USER}'`);

  await signIn(page);
  await page.goto("/account/notifications");

  // THE PAIRING. Without this, "the warning appears" would also pass against a screen that showed
  // the warning to everybody and never offered the switch at all.
  await expect(
    page.getByRole("switch", { name: /text me recovery call-outs/i }),
    "a volunteer with a number can choose",
  ).toBeVisible({ timeout: 30_000 });

  await expect(
    page.getByText(/no phone number on your volunteer profile/i),
    "and is not told anything is missing",
  ).toBeHidden();
});

test("with no number, the member is told which number is missing and where to add it", async ({
  page,
}) => {
  // Exactly the production state: a volunteer profile, availability on, and no phone on it.
  psql(`update public.responders set phone = null where user_id = '${MIKE_USER}'`);

  await signIn(page);
  await page.goto("/account/notifications");

  await expect(
    page.getByText(/no phone number on your volunteer profile/i),
    "the screen says a number is missing from the VOLUNTEER PROFILE specifically",
  ).toBeVisible({ timeout: 30_000 });

  // The distinction that makes the message worth printing: somebody reading it has probably
  // verified a phone already, on the account screen, where it does nothing for dispatch.
  await expect(
    page.getByText(/a number on your account is not the same thing/i),
    "and says plainly that a number on the account is a different thing",
  ).toBeVisible();

  const fix = page.getByRole("link", { name: /add your number to your volunteer profile/i });
  await expect(fix, "with a link to the screen that writes it").toBeVisible();
  await expect(fix).toHaveAttribute("href", /\/join$/);

  // And no switch, because flipping one would change nothing.
  await expect(
    page.getByRole("switch", { name: /text me recovery call-outs/i }),
    "and no switch, because consenting would change nothing without a number",
  ).toBeHidden();
});

test("the link goes to the form that writes the number", async ({ page }) => {
  await signIn(page);
  await page.goto("/account/notifications");

  await page
    .getByRole("link", { name: /add your number to your volunteer profile/i })
    .click();

  await page.waitForURL(/\/join/, { timeout: 20_000 });
  await expect(
    page.getByRole("heading", { level: 1 }),
    "/join renders, which is the only screen that writes responders.phone",
  ).toBeVisible({ timeout: 20_000 });
});
