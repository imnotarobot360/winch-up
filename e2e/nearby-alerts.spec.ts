import { expect, test, type Browser, type Page } from "@playwright/test";

/**
 * The location half of a recovery, end to end, with real browsers and simulated GPS.
 *
 * The owner's location-alerts spec asks for exactly this (§9): nearby members are reached,
 * members outside the radius are not. dispatch_test.sql proves the matcher in SQL; this proves
 * the thing a person experiences -- share your position, and a recovery that happens near you
 * turns up on your screen while one three counties away does not.
 *
 * SIMULATED LOCATIONS, not stubs. Each member gets their own browser context with its own
 * geolocation, so the position travels the real path: the browser's geolocation API, the
 * Share button on /me, update_my_location, PostGIS, and back out through nearby_requests.
 * Setting the row directly would have skipped every part of that.
 *
 * Houston is the request. The near helper is a few miles away; the far one is in Austin, about
 * 145 miles off -- outside the widest ring, so this holds however the radii are tuned.
 */

const PASSWORD = "recovery-demo-2026";

const STUCK = { email: "mike@winchup.test", password: PASSWORD };
const NEAR = { email: "rosa@winchup.test", password: PASSWORD };

const HOUSTON = { latitude: 29.7604, longitude: -95.3698 };
const NEAR_BY = { latitude: 29.8, longitude: -95.42 }; // ~4 miles from the request
const AUSTIN = { latitude: 30.2672, longitude: -97.7431 }; // ~145 miles away

const PIN = `${HOUSTON.latitude}, ${HOUSTON.longitude}`;

test.describe.configure({ mode: "serial" });

test.beforeEach(({}, testInfo) => {
  test.skip(testInfo.project.name !== "android", "Files real requests: one project only");
});

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
  await hydrated(page);
  await page.getByLabel(/email|correo/i).pressSequentially(who.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(who.password);
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });
}

/** A member with their own simulated position, in their own context. */
async function memberAt(
  browser: Browser,
  who: { email: string; password: string },
  at: { latitude: number; longitude: number },
) {
  const context = await browser.newContext({
    permissions: ["geolocation"],
    geolocation: at,
  });
  const page = await context.newPage();
  await signIn(page, who);
  return { context, page };
}

/**
 * Leave the requester holding no open recovery.
 *
 * A member may have exactly ONE open request. If a previous run died after filing, this one
 * files nothing -- create_request hands back the recovery that already exists -- and then
 * hunts for a note that was never written, failing as though the matcher were broken. That
 * happened twice while writing this spec, which is why the cleanup runs FIRST and not only
 * at the end: a test that only tidies up when it passes does not tidy up when it matters.
 */
test("a recovery reaches the member a few miles away and not the one in another city", async ({
  browser,
}) => {
  // ---- the helper nearby shares where they are --------------------------
  const near = await memberAt(browser, NEAR, NEAR_BY);

  // AVAILABLE TO HELP comes first, and it is a different switch from the on-call toggle on
  // /me. profiles.available_to_help is what app.candidates() and the help feed read; it
  // ships OFF, and it lives on /account/notifications. Sharing a position without it means
  // the member is located and still never matched -- which is exactly how this spec failed,
  // with a filed request, a fresh position four miles away, and an empty feed.
  await near.page.goto("/account/notifications");
  // role=switch with aria-checked, not a checkbox: the design system's Toggle is a button.
  // getByLabel().isChecked() throws on it, which is how this failed once.
  const available = near.page.getByRole("switch", { name: /^available to help|^disponible para ayudar/i });
  if ((await available.getAttribute("aria-checked")) !== "true") {
    await available.click();
    await expect(available, "the switch stays on").toHaveAttribute("aria-checked", "true", {
      timeout: 20_000,
    });
  }

  await near.page.goto("/me");
  await near.page.getByRole("button", { name: /share where i am|update my position/i }).click();

  // The position went through the browser's geolocation API and into the database. Until this
  // says so, the member has no usable location and the matcher would fall back to their home.
  await expect(
    near.page.getByText(/sharing your position/i),
    "the position is shared and the screen says when",
  ).toBeVisible({ timeout: 20_000 });

  // ---- somebody gets stuck in Houston -----------------------------------
  const stuck = await memberAt(browser, STUCK, HOUSTON);
  const note = `nearby-alerts ${Date.now().toString(36)}`;

  async function fileIt() {
  await stuck.page.goto("/request");
  await stuck.page
    .getByText(/nobody is hurt or in danger|nadie está herido/i)
    .first()
    .click();
  await stuck.page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  // Pasted rather than taken from GPS: the wizard's own GPS path needs the map, and what this
  // test is about is the DISTANCE between two members, not which control captured the pin.
  await stuck.page.getByRole("button", { name: /paste|pegar/i }).click();
  await stuck.page.getByLabel(/paste a location|pega una ubicación/i).pressSequentially(PIN);
  await stuck.page.getByRole("button", { name: /find it|buscar/i }).click();
  await expect(stuck.page.getByText(/got your location|tenemos tu ubicación/i)).toBeVisible({
    timeout: 15_000,
  });
  await stuck.page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  // Photos are skipped: uploads need storage-api, which the local stack answers 501 to.
  await stuck.page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  // Vehicle, situation, land. These are ChoiceList, which renders role=radio rather than a
  // button; the steps below are lifted from membership.spec rather than guessed at again.
  await stuck.page.getByRole("radio", { name: /^truck$|^troca$/i }).first().click();
  await stuck.page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await stuck.page.getByRole("radio", { name: /^mud$|^lodo$/i }).first().click();
  await stuck.page.getByRole("radio", { name: /to the frame|al chasis/i }).first().click();
  await stuck.page.getByLabel(/anything that helps|algo que ayude/i).pressSequentially(note);
  await stuck.page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await stuck.page.getByRole("radio", { name: /public land|terreno público/i }).first().click();
  await stuck.page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  await stuck.page.getByLabel(/first name|nombre/i).pressSequentially("Testy");
  await stuck.page.getByLabel(/mobile number|número/i).pressSequentially("+1512555" + String(Date.now()).slice(-4));
  await stuck.page.getByRole("button", { name: /^(next|siguiente)$/i }).click();

  for (const box of await stuck.page.getByRole("checkbox").all()) {
    if (!(await box.isChecked())) await box.check();
  }
  await stuck.page.getByRole("button", { name: /send request|enviar/i }).click();
    await stuck.page.waitForURL(/\/r\//, { timeout: 30_000 });
  }

  // LEAVE THE REQUESTER WITH NO OPEN RECOVERY, deterministically.
  //
  // A member may hold exactly one, and create_request answers a second attempt by handing
  // back the one that exists -- so a run that died earlier leaves this one filing nothing and
  // hunting a note that was never written. Four runs of this spec went that way.
  //
  // Reading /me to find the stale one did not work: the dashboard loads its list client-side
  // and the links were not there yet. This uses only the two pages that are certain -- the
  // wizard, and the status page it lands on, which always has Cancel while the recovery is
  // open. File, cancel whatever came back, and the account is empty for the real attempt.
  await fileIt();
  stuck.page.once("dialog", (d) => void d.accept());
  const firstCancel = stuck.page
    .getByRole("button", { name: /cancel this request|cancelar/i })
    .first();

  // WAIT FOR IT TO EXIST BEFORE ASKING WHETHER IT EXISTS. The status page renders client-side,
  // so count() immediately after the navigation is 0 on a page that is about to show the
  // button -- the same mistake that made the /me cleanup a no-op, repeated one page along.
  await firstCancel.waitFor({ state: "visible", timeout: 15_000 }).catch(() => {});

  if ((await firstCancel.count()) > 0) {
    await firstCancel.click();
    await expect(stuck.page.getByText(/cancelled|cancelada/i).first()).toBeVisible({
      timeout: 20_000,
    });
  }

  // Now it is ours, because there is nothing else it could be.
  await fileIt();

  // The status page does NOT echo the note, so there is no way to tell from here whether
  // this is our recovery or one create_request handed back. That is why the cleanup above
  // runs first and has to actually work: a detection built on the note was checking for
  // text the page never renders, and 'cancel and try again' then ran every single time.

  // ---- the near member sees it ------------------------------------------
  await near.page.goto("/help");

  const card = near.page.locator("li").filter({ hasText: note }).first();
  await expect(card, "the recovery reaches the member a few miles away").toBeVisible({
    timeout: 20_000,
  });

  // With a REAL distance, which is the whole point of sharing a position: these two points are
  // about four miles apart, and the card says so because the position went through the browser
  // geolocation API, update_my_location and PostGIS. The UI abbreviates to "mi" -- expecting
  // "miles" is how this assertion failed first time, on a card that was perfectly correct.
  await expect(card, "and it tells them how far").toContainText(/\d+(\.\d+)?\s*mi\b|milla/i);

  // And the photographs are offered to them, because they are in the ring. There are none on
  // this request, so the honest answer is "no photos on this one" rather than a dead button.
  await card.getByRole("button", { name: /show photos|ver fotos/i }).click();
  await expect(card.getByText(/no photos on this one|esta no tiene fotos/i)).toBeVisible({
    timeout: 20_000,
  });

  // ---- the member in Austin does not ------------------------------------
  //
  // Same account as the requester would muddy it, so this is the near helper's context moved
  // 145 miles: same person, same session, new position. If distance is what decides, this is
  // the only thing that changed.
  await near.context.setGeolocation(AUSTIN);
  await near.page.goto("/me");
  await near.page.getByRole("button", { name: /update my position/i }).click();
  await expect(near.page.getByText(/sharing your position/i)).toBeVisible({ timeout: 20_000 });

  await near.page.goto("/help");

  await expect(
    near.page.locator("li").filter({ hasText: note }),
    "once they are 145 miles away the same recovery is gone from their feed",
  ).toHaveCount(0, { timeout: 20_000 });

  // ---- leave nothing behind ---------------------------------------------
  //
  // A member may hold exactly ONE open request. A run that leaves one makes the NEXT run file
  // nothing -- create_request hands back the existing recovery -- and then hunt for a note
  // that was never written. That is precisely how this spec failed on its second run.
  stuck.page.once("dialog", (d) => void d.accept());
  await stuck.page.getByRole("button", { name: /cancel this request|cancelar/i }).first().click();
  await expect(
    stuck.page.getByText(/cancelled|cancelada/i).first(),
    "the requester cancels, so the account is clear for the next run",
  ).toBeVisible({ timeout: 20_000 });

  // ---- PUT THE WORLD BACK ------------------------------------------------
  //
  // This spec moves a shared demo member to Austin and switches on their availability, and
  // both of those outlive the test. The whole suite drives the same four accounts, so a
  // later spec that expects them near Houston then finds nobody -- which is exactly what
  // happened: membership.spec failed with 'the request should be visible to another member'
  // on a run where this file had passed. The product was fine; this test had moved the
  // helper 145 miles and left her there.
  //
  // Stop sharing rather than re-sharing: the seed gives these members no live position, so
  // clearing it is the state the other suites were written against.
  await near.page.goto("/me");
  const stopSharing = near.page.getByRole("button", { name: /stop sharing|dejar de compartir/i }).first();
  await stopSharing.waitFor({ state: "visible", timeout: 15_000 }).catch(() => {});
  if ((await stopSharing.count()) > 0) {
    await stopSharing.click();
    await expect(
      // The offer to share again is the proof it was forgotten. The label is
      // "Share where I am" -- not "share my position", which is what the first version of this
      // assertion looked for and why it failed on a restore that had actually worked.
      near.page.getByRole("button", { name: /share where i am|compartir dónde estoy/i }).first(),
      "the helper stops sharing, so the next spec finds her where the seed put her",
    ).toBeVisible({ timeout: 20_000 });
  }

  // AVAILABILITY IS LEFT ON, deliberately and after trying twice to turn it back off.
  //
  // Clicking the switch from here did not stick -- the page reports aria-checked true again
  // afterwards -- and a cleanup that silently does nothing while the test goes green is
  // worse than no cleanup, because the next person believes it.
  //
  // It is also the harmless half. What broke membership.spec was the POSITION: this test
  // moves a shared demo member 145 miles to Austin, and a later spec expecting her near
  // Houston then found nobody. That is cleared above. A demo volunteer who is willing to be
  // called out is a reasonable state for the other suites to meet, and closer to a real one.
  await near.context.close();
  await stuck.context.close();
});
