import { expect, test, type Page } from "@playwright/test";

/**
 * Spec section 14, with four accounts: a recovery team, its conversation, and the person who is
 * not on it.
 *
 * A files a request. B and C both offer, and A takes BOTH — a winch truck and a tractor, which is
 * the ordinary case this whole phase exists for. D is refused the conversation. All three on the
 * team talk to each other, B and C say where they have got to, A closes it, and the thread goes
 * read-only.
 *
 * WHY THIS EXISTS RATHER THAN MORE pgTAP
 *
 * The database suites for this phase all built their team by inserting recovery_participants
 * directly. Every one of them passed while the feature was, from the outside, unusable: the
 * second accept was refused, the offers vanished from the screen the moment the first helper was
 * picked, and a second helper's dashboard showed them no job and therefore no chat. Three gaps,
 * none visible to a test that starts from a team that already exists.
 *
 * So this one starts from four sign-in screens and clicks. It is slow and it is worth it.
 *
 * RUNNING THIS LOCALLY COSTS THE MEMBERSHIP SUITE ITS BUDGET
 *
 * limits.max_requests_per_ip_per_hour is 5. membership.spec files two requests a pass, this one
 * files one, and everything comes from ::1 — so locally the two suites together get through the
 * hour's allowance faster than either did alone, and the next pass fails at the wizard's final
 * step with a rate-limit error that looks nothing like a rate limit. That is the limiter working.
 *
 * Clear it between local passes:
 *
 *   psql -h 127.0.0.1 -p 55432 -U postgres -d winchup \
 *     -c "delete from rate_limit_hits where bucket_key like 'request:%';"
 *
 * On CI the database is fresh every run and it never comes up.
 *
 * D IS AN ADMIN ON PURPOSE
 *
 * The obvious fourth account is a random member. An admin is the stronger test: app.
 * is_request_participant() has no admin branch, deliberately, so if even an admin cannot read a
 * recovery conversation then nobody outside the team can. It is also the realistic near-miss --
 * an admin is exactly who would have been given a peek "for support reasons".
 */

const A = { email: "rosa@winchup.test", password: "recovery-demo-2026" };
const B = { email: "mike@winchup.test", password: "recovery-demo-2026" };
// approval = 'pending' and available_to_help = false. Both deliberate: universal membership means
// choosing to offer is the only qualification, and nobody has to approve it.
const C = { email: "pending@winchup.test", password: "recovery-demo-2026" };
const D = { email: "admin@winchup.test", password: "recovery-demo-2026" };

const PIN = "29.7604, -95.3698";

/** Letters only: Date.now()'s thirteen digits trip LONG_DIGIT_RUN in contains_contact_info. */
function runTag(prefix: string): string {
  const letters = Math.random().toString(36).replace(/[^a-z]/g, "");
  return `${prefix}${letters.slice(0, 6).padEnd(6, "x")}`;
}

function testPhone(): string {
  return `512555${String(Math.floor(1000 + Math.random() * 9000))}`;
}

test.describe.configure({ mode: "serial" });

// Four sign-ins, an eight-step wizard, two offers, two acceptances, three messages and two status
// changes, all against a real database. Slow because it is doing the whole job.
test.setTimeout(300_000);

test.beforeEach(({}, testInfo) => {
  test.skip(
    testInfo.project.name !== "android",
    "State-machine suite: one project only, or four browsers fight over four accounts",
  );
});

async function signIn(page: Page, who: { email: string; password: string }) {
  await page.goto("/signin");
  // pressSequentially, not fill: on WebKit fill() on one field clears its sibling.
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

/** Close anything this account already has open. One open request per account is an index. */
async function closeAnyOpenRequest(page: Page) {
  for (let pass = 0; pass < 3; pass += 1) {
    await page.goto("/me");
    await page.getByRole("link", { name: /^help someone$/i }).waitFor({ timeout: 15_000 });

    const link = page.locator('a[href*="/r/"]').first();
    try {
      await link.waitFor({ state: "visible", timeout: 4_000 });
    } catch {
      return;
    }

    await link.click();
    await page.waitForURL(/\/r\//, { timeout: 15_000 }).catch(() => undefined);

    const cancel = page.getByRole("button", { name: /cancel this request|cancelar esta/i }).first();
    try {
      await cancel.waitFor({ state: "visible", timeout: 10_000 });
    } catch {
      return; // Already closed, and open ones sort first.
    }

    // Native window.confirm, which Playwright dismisses by default.
    page.once("dialog", (dialog) => void dialog.accept());
    await cancel.click();
    await page.waitForTimeout(2_500);
  }
}

/**
 * Step off any recovery this account is already on.
 *
 * The demo seed has Trey leading TX-DM04, and my_responder_profile() returns ONE current job,
 * ordered so a member's own lead job wins. So C signed in, went to /me, and correctly saw the
 * seeded recovery rather than this run's — the test read that as the second-helper dashboard
 * still being broken when it was working exactly as written.
 *
 * Withdrawing rather than closing: "They're out — close this job" would record somebody else's
 * seeded recovery as recovered, which is a lie left in the database. Leaving says what happened.
 *
 * (What this does expose, and is not in scope here: a member on two live recoveries only ever
 * sees one of them on /me. Rarer before teams than after.)
 */
async function leaveAnyCurrentJob(page: Page) {
  for (let pass = 0; pass < 3; pass += 1) {
    await page.goto("/me");
    await page.getByRole("link", { name: /^help someone$/i }).waitFor({ timeout: 15_000 });

    const leave = page.getByRole("button", { name: /i can no longer make it/i }).first();
    try {
      await leave.waitFor({ state: "visible", timeout: 4_000 });
    } catch {
      return; // Not on anything.
    }

    await leave.click();
    // A rendered confirmation, not window.confirm: dropping out tells everyone on the recovery.
    await page.getByRole("button", { name: /yes, i have to drop out/i }).first().click();
    await page.waitForTimeout(2_500);
  }
}

async function fileRequest(page: Page, note: string): Promise<string> {
  await page.goto("/request");

  await page.getByText(/nobody is hurt or in danger|nadie está herido/i).first().click();
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await page.getByRole("button", { name: /paste|pegar/i }).click();
  await page.getByLabel(/paste a location|pega una ubicación/i).pressSequentially(PIN);
  await page.getByRole("button", { name: /find it|buscar/i }).click();
  await expect(page.getByText(/got your location|tenemos tu ubicación/i)).toBeVisible({
    timeout: 15_000,
  });
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  // Photos skipped: uploads need storage-api, which the local stack answers 501 to on purpose.
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await page.getByRole("radio", { name: /^truck$|^troca$/i }).first().click();
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await page.getByRole("radio", { name: /^mud$|^lodo$/i }).first().click();
  await page.getByRole("radio", { name: /buried|enterrad/i }).first().click();
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await page.getByRole("radio", { name: /public land|terreno público/i }).first().click();
  await page.getByLabel(/anything else|algo más/i).pressSequentially(note);
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await page.getByLabel(/first name|nombre/i).pressSequentially("Testy");
  await page.getByLabel(/mobile number|número/i).pressSequentially(testPhone());
  await page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  for (const box of await page.getByRole("checkbox").all()) {
    if (!(await box.isChecked())) await box.check();
  }
  await page.getByRole("button", { name: /send request|enviar/i }).click();

  await page.waitForURL(/\/r\//, { timeout: 30_000 });
  return page.url();
}

async function offerOn(page: Page, note: string, eta: string) {
  await page.goto("/help");

  const card = page.locator("li").filter({ hasText: note }).first();
  await expect(card, "the request should be visible to another member").toBeVisible({
    timeout: 20_000,
  });

  await card.getByRole("button", { name: /offer to help|ofrecerme/i }).click();
  await card.getByText(/i have the gear|tengo el equipo/i).click();
  await card.getByLabel(/how long|cuánto tardas/i).pressSequentially(eta);
  await card.getByRole("button", { name: /send my offer|enviar mi ofrecimiento/i }).click();

  await expect(card.getByText(/your offer is in|tu ofrecimiento está registrado/i)).toBeVisible({
    timeout: 20_000,
  });
}

/** Say something in the recovery conversation on whatever page is currently open. */
async function sayInThread(page: Page, text: string) {
  const compose = page.getByLabel(/your message|tu mensaje/i);
  await expect(compose, "a team member can write in the conversation").toBeVisible({
    timeout: 20_000,
  });
  await compose.pressSequentially(text);
  await page.getByRole("button", { name: /^(send|enviar)$/i }).click();
  await expect(page.getByText(text, { exact: false }).first()).toBeVisible({ timeout: 20_000 });
}

test.describe("a recovery team, its conversation, and the person who is not on it", () => {
  test("two helpers accepted, a third party refused, and the thread closes with the job", async ({
    page,
  }) => {
    const note = runTag("e2e-team-");

    /* ---------------------------------------------------------------- A files it */

    await signIn(page, A);
    await closeAnyOpenRequest(page);
    const statusUrl = await fileRequest(page, note);
    await signOut(page);

    /* ------------------------------------------------- B and C both put a hand up */

    await signIn(page, B);
    await leaveAnyCurrentJob(page);
    await offerOn(page, note, "35");
    await signOut(page);

    // C is approval = 'pending'. Under universal membership that is not a gate on offering, and
    // this is the assertion that keeps it from quietly becoming one again.
    await signIn(page, C);
    await leaveAnyCurrentJob(page);
    await offerOn(page, note, "55");
    await signOut(page);

    /* --------------------------------------------------------- A takes them both */

    await signIn(page, A);
    await page.goto(statusUrl);

    await expect(page.getByText(/2 volunteers have offered/i)).toBeVisible({ timeout: 20_000 });

    // The first. This is the one that hands over a phone number.
    await page.getByRole("button", { name: /^pick /i }).first().click();
    await expect(page.getByText(/\(\d{3}\)\s?\d{3}-\d{4}/).first()).toBeVisible({
      timeout: 20_000,
    });

    // The second, which is the part that did not exist. Before 20260923002300/2400 the offers
    // card disappeared at this point and there was no button here at all.
    const addMore = page.getByRole("button", { name: /add .* to the team/i }).first();
    await expect(addMore, "the remaining offer is still on the screen after the first pick")
      .toBeVisible({ timeout: 20_000 });
    await addMore.click();

    // Two helpers plus the person who is stuck.
    await expect(page.getByText(/2 people coming/i)).toBeVisible({ timeout: 20_000 });

    await sayInThread(page, `${note} gate code is four four one two`);
    await signOut(page);

    /* ------------------------------------------------------- D is not on this job */

    await signIn(page, D);
    await page.goto(statusUrl);

    // The status page itself is reachable: it is token-scoped and gets forwarded to whoever is
    // helping, and it shows the team. The conversation is not part of that.
    //
    // Checked by short code rather than by the run tag: the tag is the requester's free-text
    // note, which the status page does not render at all. Asserting on something that is never
    // on the page would have made the two real assertions below unreachable.
    await expect(page.getByText(/^TX-[A-Z0-9]+$/).first()).toBeVisible({ timeout: 20_000 });
    await expect(
      page.getByRole("heading", { name: /recovery team/i }),
      "and it does show who is coming, which is what the link is for",
    ).toBeVisible({ timeout: 20_000 });
    await expect(
      page.getByRole("heading", { name: /^messages$/i }),
      "an admin holding the status link is not offered the recovery conversation",
    ).toHaveCount(0);
    await expect(
      page.getByText(/gate code is four four one two/i),
      "and cannot read what the team said",
    ).toHaveCount(0);

    await signOut(page);

    /* ------------------------------------------- B: the lead, from their own screen */

    await signIn(page, B);
    await page.goto("/me");
    await expect(page.getByText(/current job|trabajo actual/i).first()).toBeVisible({
      timeout: 20_000,
    });

    await expect(
      page.getByText(/gate code is four four one two/i).first(),
      "the lead can read what the requester said",
    ).toBeVisible({ timeout: 20_000 });

    await sayInThread(page, `${note} bringing the long strap`);

    // Where they have got to. Per-helper, not per-recovery.
    await page.getByRole("button", { name: /on the way/i }).first().click();
    await expect(page.getByText(/on the way/i).first()).toBeVisible({ timeout: 20_000 });
    await signOut(page);

    /* --------------------------- C: the second helper, who used to have nowhere to go */

    await signIn(page, C);
    await page.goto("/me");

    // Before 20260923002500 this card was absent for a helper who was not the lead: current_job
    // resolved through accepted_responder_id, so C had been accepted onto a recovery and the app
    // had no route back to it — no chat, no arrival controls, nothing.
    await expect(
      page.getByText(/current job|trabajo actual/i).first(),
      "a helper who is not the lead still sees the recovery they joined",
    ).toBeVisible({ timeout: 20_000 });

    await expect(page.getByText(/bringing the long strap/i).first()).toBeVisible({
      timeout: 20_000,
    });

    await sayInThread(page, `${note} tractor is on the trailer`);

    await page.getByRole("button", { name: /getting ready/i }).first().click();
    await signOut(page);

    /* ------------------------------------------------------- A closes it, thread ends */

    await signIn(page, A);
    await page.goto(statusUrl);

    // Everything all three said, in one conversation.
    await expect(page.getByText(/bringing the long strap/i).first()).toBeVisible({
      timeout: 20_000,
    });
    await expect(page.getByText(/tractor is on the trailer/i).first()).toBeVisible({
      timeout: 20_000,
    });

    await page.getByRole("button", { name: /recovered|rescatad/i }).first().click();
    const confirm = page.getByRole("button", { name: /yes|confirm|sí|mark/i }).first();
    if (await confirm.count()) await confirm.click();

    await expect(page.getByText(/recovered|rescatad/i).first()).toBeVisible({ timeout: 20_000 });

    // A finished recovery keeps its history and stops accepting messages. The server decides
    // this, not the page: read_only comes back from request_thread.
    await expect(
      page.getByLabel(/your message|tu mensaje/i),
      "the conversation is read-only once the recovery is over",
    ).toHaveCount(0);
    await expect(page.getByText(/bringing the long strap/i).first()).toBeVisible();

    await signOut(page);
  });
});
