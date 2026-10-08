import { execFileSync } from "node:child_process";
import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * An admin closes a recovery from the queue.
 *
 * WHY THIS IS A BROWSER TEST AND NOT ONLY pgTAP. admin_cancel_test.sql proves the RPC: who may
 * call it, that the dispatches are stood down, that the volunteer is texted, that the audit row is
 * written. None of that says the BUTTON works — and the button is the part that failed for the
 * owner on 2026-10-05, when they clicked Cancel in production and the request stayed open. It
 * turned out they were on a bundle deployed a minute earlier that did not contain the button,
 * which is indistinguishable from a broken feature.
 *
 * IT CANCELS A RECOVERY IT CREATED ITSELF, AND REMOVES IT AFTERWARDS.
 *
 * The first version of this file clicked the FIRST Cancel button in the queue, which is "oldest
 * first" — and the oldest happened to be a seeded ACCEPTED recovery that privacy_rls_test depends
 * on. It cancelled it, and privacy_rls_test then failed on "once a volunteer accepts, the
 * requester gets their phone number". On CI the pgTAP step runs AFTER the browser suite, so that
 * would have broken the build, with the failure pointing at a privacy function nobody had touched.
 *
 * CLAUDE.md already says a spec that changes shared demo state must put it back. The cheaper
 * answer is not to touch shared state at all: this inserts its own request, finds it by its short
 * code, cancels that one, and deletes it in teardown.
 */

const ADMIN = { email: "admin@winchup.test", password: "recovery-demo-2026" };

/** Unique per run, so two runs cannot fight over the same row. */
const CODE = `TX-E2E${String(Date.now()).slice(-2)}`;
const PHONE = "+15125550199";

test.describe.configure({ mode: "serial" });

function psql(statement: string): string {
  return execFileSync(
    // Same resolution as scripts/local-stack/rebuild.mjs, and for the same reason: psql is NOT on
    // PATH on the machine this repo is developed on -- the Postgres zip is unpacked, never
    // installed. Falling back to a bare "psql" fails with spawnSync ENOENT inside beforeAll, which
    // Playwright reports as a 0ms failure and then SKIPS the rest of the file, so four assertions
    // vanish and the run still looks mostly green. A default that works nowhere is worse than no
    // default; this one works on the machine it was written on.
    process.env.PSQL ?? "psql",
    [
      "-h", "127.0.0.1",
      "-p", process.env.PGPORT ?? "54322",
      "-U", process.env.PGUSER ?? "postgres",
      "-d", process.env.PGDATABASE ?? "postgres",
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

test.beforeAll(() => {
  // Its own recovery, so nothing seeded is disturbed. Dispatching with no volunteer: the state an
  // admin would actually be clearing.
  psql(`
    insert into public.requests (
      short_code, requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
      status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
    ) values (
      '${CODE}', 'E2E Cancel', '${PHONE}',
      extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography,
      'truck', 'mud', 'public', 'dispatching', now(), true,
      (select id from public.waivers where slug = 'requester_waiver' and is_current), now()
    )
  `);
});

test.afterAll(() => {
  // Removed whether the test passed or failed. A left-behind request would sit in the queue and in
  // every later run's counts, which is the same class of mess this file was written to stop making.
  psql(`delete from public.requests where requester_phone = '${PHONE}'`);
});

test.beforeEach(({}, testInfo) => {
  test.skip(testInfo.project.name !== "android", "Drives the admin queue: one project only");
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

/**
 * The one card for OUR recovery, found by its short code rather than by position.
 *
 * Filtered by BOTH the code and the presence of a cancel button. Filtering on the text alone
 * matches every ancestor div too, and `.last()` of those is the innermost — the little element
 * holding the code itself, which contains no button. Requiring both narrows it to the card.
 */
function ourRow(page: Page) {
  return page
    .locator("div")
    .filter({ hasText: CODE })
    .filter({ has: page.getByRole("button", { name: /^cancel$|^cancelar$/i }) })
    .last();
}

async function openQueue(page: Page) {
  await page.goto("/admin");
  await expect(
    page.getByText(CODE),
    "the queue lists the recovery this spec created",
  ).toBeVisible({ timeout: 30_000 });
}

test("the cancel control is served on the queue", async ({ page }) => {
  await signIn(page);
  await openQueue(page);

  // The assertion that would have caught the production confusion: the button is SERVED, not just
  // written. A deploy that has not landed looks exactly like a feature that does not work.
  await expect(
    ourRow(page).getByRole("button", { name: /^cancel$|^cancelar$/i }),
    "our recovery has a cancel control",
  ).toBeEnabled({ timeout: 20_000 });
});

test("dismissing the confirmation changes nothing", async ({ page }) => {
  await signIn(page);
  await openQueue(page);

  // THE CONTROL FOR THE TEST BELOW. Without it, "clicking cancel closes the recovery" would also
  // pass against a button that closed it without ever asking.
  let asked = false;
  page.once("dialog", (dialog) => {
    asked = true;
    void dialog.dismiss();
  });

  await ourRow(page).getByRole("button", { name: /^cancel$|^cancelar$/i }).click();
  await page.waitForTimeout(2000);

  expect(asked, "it asks before closing somebody's recovery").toBe(true);
  expect(
    psql(`select status from public.requests where short_code = '${CODE}'`),
    "and saying no leaves the recovery exactly as it was",
  ).toBe("dispatching");
});

test("accepting it closes the recovery and drops it off the queue", async ({ page }) => {
  await signIn(page);
  await openQueue(page);

  page.once("dialog", (dialog) => void dialog.accept());
  await ourRow(page).getByRole("button", { name: /^cancel$|^cancelar$/i }).click();

  await expect(
    page.getByText(CODE),
    "the recovery leaves the queue, so the RPC ran and the reload saw the new state",
  ).toBeHidden({ timeout: 30_000 });

  // The database, not React. A row that only left the screen has not been cancelled.
  expect(
    psql(`select status from public.requests where short_code = '${CODE}'`),
    "and it is cancelled in the database",
  ).toBe("cancelled");
});

test("the cancelled recovery is off the public board too", async ({ page }) => {
  // The whole reason an admin cancel exists: a request nobody can clear sits on the PUBLIC board.
  // Checked through the API rather than the page, because the board is what strangers see.
  const response = await page.request.get("/api/board");
  expect(response.ok(), "the public board responds").toBe(true);

  const body = (await response.json()) as
    | { short_code: string; status: string }[]
    | { requests?: { short_code: string; status: string }[] };
  const rows = Array.isArray(body) ? body : (body.requests ?? []);

  expect(
    rows.some((r) => r.short_code === CODE),
    "the cancelled recovery is not shown publicly",
  ).toBe(false);
});
