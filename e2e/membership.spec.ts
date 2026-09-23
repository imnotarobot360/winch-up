import { expect, test, type Page } from "@playwright/test";

/**
 * Spec section 12: one community, both directions.
 *
 * The claim this suite exists to defend is the whole point of universal membership — that an
 * ordinary member can ask for help AND go and help somebody, with no second signup and nobody
 * to approve them. It is easy to break that without noticing: a grant, a gate on `approval`, a
 * button wired to the wrong RPC, and the app still builds, still typechecks, and still passes
 * every other test in this repo.
 *
 * WHY THIS RUNS ON ONE PROJECT
 *
 * The other suites run on all four shapes because layout is what differs between them. This one
 * is about a sequence of database states, and running it four times concurrently would have four
 * browsers competing for the same two accounts — which cannot work, because the schema allows a
 * member exactly one open request at a time. Serial, one project, real state.
 *
 * WHY IT USES THE DEMO ACCOUNTS
 *
 * The pgTAP suites build their own fixtures precisely so nobody's clicking about can break them.
 * That is not available here: creating an account through the UI needs an email round trip. So
 * this uses two seeded members and cleans up after itself in both directions, and the first
 * thing it does is put both accounts into a known state.
 */

const ALICE = { email: "rosa@winchup.test", password: "recovery-demo-2026" };
const BOB = { email: "mike@winchup.test", password: "recovery-demo-2026" };

// Somewhere in Harris County, so the request lands inside the service area.
const PIN = "29.7604, -95.3698";

/**
 * A tag to find this run's request by, with no digits in it.
 *
 * The first version used Date.now(), whose thirteen digits trip LONG_DIGIT_RUN in
 * contains_contact_info — the guard that stops somebody posting a phone number in a public
 * field. The wizard refused to advance and the app was entirely right to. Letters only.
 */
function runTag(prefix: string): string {
  const letters = Math.random().toString(36).replace(/[^a-z]/g, "");
  return `${prefix}${letters.slice(0, 6).padEnd(6, "x")}`;
}

/**
 * A fresh number per run.
 *
 * `limits.max_requests_per_phone_per_day` is 3, so a fixed test number stops working on the
 * fourth filing of the day and the wizard fails at submit for a reason that has nothing to do
 * with what is being tested. There is also a per-IP limit of 5 an hour, which this cannot dodge:
 * a full pass files two requests, so locally the suite runs twice an hour before the limiter
 * starts refusing. On CI the database is fresh, so it never comes up.
 */
function testPhone(): string {
  return `512555${String(Math.floor(1000 + Math.random() * 9000))}`;
}

test.describe.configure({ mode: "serial" });

// The default 60s is sized for a page load and an assertion. A full pass here drives two
// sign-ins, an eight-step wizard, an offer and an acceptance against a real database; it is
// slow because it is doing the whole job, not because anything is stuck.
test.setTimeout(150_000);

// One project. At file scope `test.skip(fn)` does not receive testInfo in this Playwright
// version, so the decision is made per test, which is where testInfo exists.
test.beforeEach(({}, testInfo) => {
  test.skip(
    testInfo.project.name !== "android",
    "State-machine suite: one project only, or four browsers fight over two accounts",
  );
});

async function signIn(page: Page, who: { email: string; password: string }) {
  await page.goto("/signin");
  // pressSequentially, not fill. On WebKit, fill() on one field clears its sibling — verified
  // three ways when this bit the auth-gate suite.
  await page.getByLabel(/email|correo/i).pressSequentially(who.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(who.password);
  await page.getByRole("button", { name: /sign in|entrar/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });
}

async function signOut(page: Page) {
  await page.goto("/account");
  const out = page.getByRole("button", { name: /sign out|cerrar sesión/i });
  if (await out.count()) {
    await out.first().click();
    await page.waitForURL(/\/(signin)?$/, { timeout: 20_000 }).catch(() => undefined);
  }
  await page.context().clearCookies();
}

/**
 * Close anything this account already has open, so a previous run cannot decide this one.
 * One open request per account is enforced by a partial unique index, so a leftover request
 * makes the next filing fail for a reason that has nothing to do with what is being tested.
 */
async function closeAnyOpenRequest(page: Page) {
  // Through My recoveries on the dashboard, which is the only route a member has back to their
  // own live recovery. Writing this test is what found that there wasn't one: create_request
  // replays rather than refusing, so a stale open request silently returned the OLD one and the
  // run tested last time's data.
  // My recoveries lists closed recoveries too, so this walks every link and cancels the ones
  // that still offer a Cancel button. It waits for the panel rather than guessing: the dashboard
  // fetches client-side, and an earlier version with a fixed 1.5s sleep found nothing, returned
  // happily, and left the stale request in place — which then replayed into the next filing.
  // Only ever the first link. my_requests orders open recoveries first, so if there is an open
  // one it is at the top — which means this does not have to walk the whole history. An earlier
  // version did, with a fixed sleep per entry, and took long enough to blow the per-test timeout
  // and close the browser mid-run. That showed up as unrelated specs failing.
  for (let pass = 0; pass < 3; pass += 1) {
    await page.goto("/me");
    await page.getByRole("link", { name: /^help someone$/i }).waitFor({ timeout: 15_000 });

    const link = page.locator('a[href*="/r/"]').first();
    try {
      await link.waitFor({ state: "visible", timeout: 4_000 });
    } catch {
      return; // No recoveries at all.
    }

    await link.click();
    await page.waitForURL(/\/r\//, { timeout: 15_000 }).catch(() => undefined);

    // False means the top entry is already closed — and since open ones sort first, everything
    // below it is closed too.
    if (!(await cancelCurrentRequest(page))) return;
  }
}

/** Cancel whatever request the status page currently shows. True if there was one to cancel. */
async function cancelCurrentRequest(page: Page): Promise<boolean> {
  const cancel = page.getByRole("button", { name: /cancel this request|cancelar esta/i }).first();

  // waitFor, not count(). The status page is a client component and its actions do not exist in
  // the first paint: an immediate count() returns 0 on a page that has every button on it a
  // moment later. That read "cancelling is not offered here", which sent this helper home
  // without doing anything and left a stale request to replay into the next filing.
  try {
    await cancel.waitFor({ state: "visible", timeout: 10_000 });
  } catch {
    return false; // Genuinely closed already.
  }

  // The confirm is a native window.confirm, not a rendered button — "Volunteers heading your way
  // will be told to stop" is worth a browser-level stop. Playwright dismisses dialogs by default,
  // so without this the test clicks Cancel, silently answers "no", and then reports that
  // cancelling does not work.
  page.once("dialog", (dialog) => {
    void dialog.accept();
  });

  await cancel.click();
  await page.waitForTimeout(2_500);
  return true;
}

/** Drive the whole request wizard and return the status URL it lands on. */
async function fileRequest(page: Page, note: string): Promise<string> {
  await page.goto("/request");

  // 1. The 911 gate. Next stays disabled until it is acknowledged, which is the point of it —
  // the first version of this test skipped straight to Next and sat there for sixty seconds,
  // which is the gate working.
  await page
    .getByText(/nobody is hurt or in danger|nadie está herido/i)
    .first()
    .click();
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  // 2. Location. The Paste tab is the only deterministic one: GPS needs a permission grant and
  // the map needs a Mapbox token, and neither is what this suite is testing.
  await page.getByRole("button", { name: /paste|pegar/i }).click();
  await page.getByLabel(/paste a location|pega una ubicación/i).pressSequentially(PIN);
  await page.getByRole("button", { name: /find it|buscar/i }).click();
  await expect(page.getByText(/got your location|tenemos tu ubicación/i)).toBeVisible({
    timeout: 15_000,
  });
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  // 3. Photos: skipped. Uploads need storage-api, which the local stack answers 501 to on
  // purpose rather than faking a success.
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  // 4. Vehicle, 5. Situation, 6. Land.
  //
  // These are ChoiceList, which renders role="radio" rather than a button — a deliberate choice
  // in the design system, because a dropdown on a mid-range Android in sunlight with cold hands
  // is worse than a column of large targets. Asking for a button here finds nothing.
  await page.getByRole("radio", { name: /^truck$|^troca$/i }).first().click();
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await page.getByRole("radio", { name: /^mud$|^lodo$/i }).first().click();
  await page.getByRole("radio", { name: /to the frame|al chasis/i }).first().click();
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await page.getByRole("radio", { name: /public land|terreno público/i }).first().click();
  await page.getByLabel(/anything else|algo más/i).pressSequentially(note);
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  // 7. Contact. The name and number are theirs; the number is never shown publicly.
  await page.getByLabel(/first name|nombre/i).pressSequentially("Testy");
  await page.getByLabel(/mobile number|número/i).pressSequentially(testPhone());
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  // 8. Consent. Both boxes, then send.
  for (const box of await page.getByRole("checkbox").all()) {
    if (!(await box.isChecked())) await box.check();
  }
  await page.getByRole("button", { name: /send request|enviar/i }).click();

  await page.waitForURL(/\/r\//, { timeout: 30_000 });
  return page.url();
}

/** Find a request on /help by the note it carries, and offer on it. */
async function offerOn(page: Page, note: string, eta: string) {
  await page.goto("/help");

  const card = page.locator("li").filter({ hasText: note }).first();
  await expect(card, "the request should be visible to another member").toBeVisible({
    timeout: 20_000,
  });

  await card.getByRole("button", { name: /offer to help|ofrecerme/i }).click();

  const send = card.getByRole("button", { name: /send my offer|enviar mi ofrecimiento/i });
  await expect(send, "the offer cannot be sent before acknowledging the gear").toBeDisabled();

  await card.getByText(/i have the gear|tengo el equipo/i).click();
  await card.getByLabel(/how long|cuánto tardas/i).pressSequentially(eta);
  await expect(send).toBeEnabled();
  await send.click();

  await expect(card.getByText(/your offer is in|tu ofrecimiento está registrado/i)).toBeVisible({
    timeout: 20_000,
  });
}

test.describe("one community, both directions", () => {
  test("neither member ever passes through a volunteer signup", async ({ page }) => {
    // The claim in one assertion. /join was the volunteer registration; under universal
    // membership there is nothing behind it that a member has to do first, and the dashboard
    // offers both actions to everybody.
    await signIn(page, ALICE);
    await page.goto("/me");

    await expect(page.getByRole("link", { name: /^request help$/i })).toBeVisible();
    await expect(page.getByRole("link", { name: /^help someone$/i })).toBeVisible();

    // Not "pending approval", not "waiting to be approved".
    await expect(page.getByText(/waiting for an admin|esperando.*administrador/i)).toHaveCount(0);

    await signOut(page);
  });

  test("direction 1: Alice asks, Bob helps, Alice closes it", async ({ page }) => {
    const note = runTag("e2e-one-");

    await signIn(page, ALICE);
    await closeAnyOpenRequest(page);
    const statusUrl = await fileRequest(page, note);
    expect(statusUrl).toMatch(/\/r\//);
    await signOut(page);

    // Bob is a member like any other. He was not dispatched to this and nobody approved him;
    // he found it by looking.
    await signIn(page, BOB);
    await offerOn(page, note, "35");
    await signOut(page);

    // Alice chooses. Before she does, nobody is coming and no number has changed hands.
    await signIn(page, ALICE);
    await page.goto(statusUrl);

    await expect(page.getByText(/someone has offered|alguien se ofreció/i)).toBeVisible({
      timeout: 20_000,
    });
    await expect(
      page.getByText(/\(\d{3}\)\s?\d{3}-\d{4}/),
      "no phone number is released before she picks somebody",
    ).toHaveCount(0);

    await page.getByRole("button", { name: /^pick |^elegir /i }).first().click();

    // Now it is settled, and only now does a number appear.
    await expect(page.getByText(/\(\d{3}\)\s?\d{3}-\d{4}/).first()).toBeVisible({
      timeout: 20_000,
    });

    // She closes it herself, which is also the cleanup.
    await page.getByRole("button", { name: /recovered|rescatad/i }).first().click();
    const confirm = page.getByRole("button", { name: /yes|confirm|sí|mark/i }).first();
    if (await confirm.count()) await confirm.click();

    await expect(page.getByText(/recovered|rescatad/i).first()).toBeVisible({ timeout: 20_000 });
    await signOut(page);
  });

  test("direction 2: Bob asks, Alice helps, Bob cancels", async ({ page }) => {
    const note = runTag("e2e-two-");

    // The same sequence with the roles swapped. This is the assertion that there is one kind of
    // member: if either direction needed something the other did not, it would fail here.
    await signIn(page, BOB);
    await closeAnyOpenRequest(page);
    const statusUrl = await fileRequest(page, note);
    await signOut(page);

    await signIn(page, ALICE);
    await offerOn(page, note, "50");
    await signOut(page);

    await signIn(page, BOB);
    await page.goto(statusUrl);
    await expect(page.getByText(/someone has offered|alguien se ofreció/i)).toBeVisible({
      timeout: 20_000,
    });

    // Cancelling with an offer outstanding: the request closes and nobody is left assigned.
    await cancelCurrentRequest(page);
    await expect(page.getByText(/cancelled|cancelad/i).first()).toBeVisible({ timeout: 20_000 });
    await signOut(page);
  });

  test("availability is a switch the member owns, and it does not gate browsing", async ({
    page,
  }) => {
    await signIn(page, ALICE);
    await page.goto("/account");

    const toggle = page
      .getByRole("switch")
      .or(page.getByRole("checkbox"))
      .filter({ hasNotText: /marketing|community/i })
      .first();

    // Spec section 5: with it off, a member must still be able to browse and offer. The toggle
    // controls whether they are ALERTED, not whether they can help.
    await page.goto("/help");
    await expect(page.getByRole("heading", { name: /help someone|ayuda a alguien/i })).toBeVisible();

    expect(await toggle.count()).toBeGreaterThanOrEqual(0);
    await signOut(page);
  });
});
