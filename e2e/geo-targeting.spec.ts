import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * Announcements, a member's stated area, and the Content & Marketing screen.
 *
 * WHY THIS EXISTS WHEN THERE ARE 1238 pgTAP ASSERTIONS. Because they prove the database is right
 * and nothing more. CLAUDE.md records the phase that shipped with 686 passing assertions and a
 * recovery team nobody could actually join: the suites built their teams by INSERTING participant
 * rows, so they never asked whether any of the three layers above would let somebody in.
 *
 * The same shape applies here. `my_announcements()` can be perfect while the banner never mounts,
 * `set_my_location()` can be perfect while the form cannot reach it, and `admin_announcements()`
 * can be perfect while the screen renders an empty list. Each of those failures is invisible to
 * pgTAP and obvious in a browser.
 *
 * It also pins the one thing I checked by hand on 2026-10-03 and could not otherwise repeat:
 * publish as an admin, see it as a member, dismiss it, and have the dismissal survive a reload.
 *
 * One project, like every other suite that writes real rows -- four browsers sharing four demo
 * accounts fight over them otherwise.
 */

const ADMIN = { email: "admin@winchup.test", password: "recovery-demo-2026" };
const MEMBER = { email: "mike@winchup.test", password: "recovery-demo-2026" };

test.describe.configure({ mode: "serial" });

test.beforeEach(({}, testInfo) => {
  test.skip(
    testInfo.project.name !== "android",
    "Publishes real announcements and edits a shared profile: one project only",
  );
});

/**
 * Wait for React to attach to a given element before typing into it.
 *
 * Keystrokes delivered before hydration are undone when it happens, leaving the form empty and the
 * submit disabled -- which reads as a broken form. Same wait as events.spec and blocked.spec.
 *
 * IT TAKES THE ELEMENT RATHER THAN GUESSING AT ONE. The first version anchored on `form, main`,
 * copied from the specs that only ever visit pages with a <main>. The admin layout has neither --
 * it is a bare <div> -- so the wait timed out after sixty seconds on a page that was rendering
 * perfectly well, and the failure named the locator rather than the missing element.
 */
async function hydrated(target: Locator) {
  await target
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
  await hydrated(page.locator("form"));

  // pressSequentially, not fill: Playwright's fill() clears a sibling field on WebKit, which is
  // why every form in this suite is typed.
  await page.getByLabel(/email|correo/i).pressSequentially(who.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(who.password);
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });
}

async function signOut(page: Page) {
  await page.context().clearCookies();
}

/** The card for one announcement, found by its heading rather than by position in a list. */
function cardFor(page: Page, marker: string) {
  return page
    .locator("div")
    .filter({ has: page.getByRole("heading", { name: marker }) })
    .last();
}

test("an announcement published by an admin reaches a member, and dismissing it sticks", async ({
  page,
}) => {
  const marker = `Gate notice ${Date.now().toString(36)}`;

  // ---- the admin publishes it -------------------------------------------------
  await signIn(page, ADMIN);
  await page.goto("/admin/content");
  // No <main> in the admin layout, so this anchors on a control AdminContent itself renders.
  await hydrated(page.getByRole("button", { name: /^announcements$/i }));

  await expect(
    page.getByRole("heading", { name: /content & marketing/i }),
    "the admin screen renders at all -- it is reached only from the admin nav",
  ).toBeVisible();

  await page.getByLabel(/^title$/i).pressSequentially(marker);
  await page
    .getByLabel(/^message$/i)
    .pressSequentially("The north gate is chained. Do not drive out expecting to get in.");

  await page.getByRole("button", { name: /^publish$/i }).click();

  // It comes back from the database with its audience counted, which is section 14's number and
  // the thing an admin is deciding on. Untargeted, so it reaches everybody.
  const adminCard = cardFor(page, marker);
  await expect(adminCard, "the published announcement appears in the admin list").toBeVisible({
    timeout: 20_000,
  });
  await expect(adminCard, "with an estimated audience and a count of places").toContainText(
    /\d+ members? · \d+ places targeted/i,
  );

  // ---- the member sees it -----------------------------------------------------
  await signOut(page);
  await signIn(page, MEMBER);
  await page.goto("/community");
  await hydrated(page.locator("main"));

  const banner = page.getByRole("heading", { name: marker });
  await expect(
    banner,
    "a DIFFERENT member sees it on /community -- the banner mounts and my_announcements answers",
  ).toBeVisible({ timeout: 20_000 });

  // ---- dismissing it is a row, not local state --------------------------------
  await cardFor(page, marker).getByRole("button", { name: /^dismiss$/i }).click();
  await expect(banner, "it goes away when closed").toBeHidden({ timeout: 20_000 });

  await page.reload();
  await hydrated(page.locator("main"));
  await expect(
    page.getByRole("heading", { name: marker }),
    "AND IT STAYS GONE ACROSS A RELOAD, which is the only thing that distinguishes a dismissal " +
      "that was written from one that only happened in the browser",
  ).toHaveCount(0, { timeout: 20_000 });

  // ---- put the shared database back -------------------------------------------
  // Every run of this suite publishes to the same four demo accounts. An announcement left behind
  // is visible to the other three for ever and stacks up one per run, so it is archived -- and the
  // archive is ASSERTED, because a cleanup that cannot fail is a cleanup you cannot trust.
  await signOut(page);
  await signIn(page, ADMIN);
  await page.goto("/admin/content");
  // No <main> in the admin layout, so this anchors on a control AdminContent itself renders.
  await hydrated(page.getByRole("button", { name: /^announcements$/i }));

  const toArchive = cardFor(page, marker);
  await expect(toArchive).toBeVisible({ timeout: 20_000 });
  await toArchive.getByRole("button", { name: /^archive$/i }).click();

  // IT STAYS IN THE ADMIN LIST, and that is correct rather than a failed cleanup: this screen shows
  // every status so an admin can find what they archived. What changes is the badge -- and because
  // my_announcements() returns published rows only, archived is exactly "no longer reaching anybody".
  await expect(
    cardFor(page, marker),
    "the announcement this run created now reads Archived, so it reaches nobody on the next run",
  ).toContainText(/archived/i, { timeout: 20_000 });
});

test("a member can state an area, it survives a reload, and it can be removed", async ({
  page,
}) => {
  await signIn(page, MEMBER);
  await page.goto("/account/location");
  await hydrated(page.locator("main"));

  // The screen loads its current value before it shows the form. If this never resolves the form
  // never appears, which is exactly what a missing column grant on `profiles` looks like -- the
  // whole select is refused rather than one column, and the screen sits on "Loading...".
  const city = page.getByLabel(/town or city/i);
  await expect(city, "the form appears, so the profile read succeeded").toBeVisible({
    timeout: 20_000,
  });

  await city.pressSequentially("Cypress");
  await page.getByLabel(/^state$/i).pressSequentially("tx");
  await page.getByLabel(/zip code/i).pressSequentially("77429");

  // Typed lower case on purpose: the column is constrained to two capitals, so a member typing
  // "tx" would be refused by the database for being right. The field upper-cases as it goes.
  await expect(page.getByLabel(/^state$/i), "the state is upper-cased as it is typed").toHaveValue(
    "TX",
  );

  await page.getByRole("button", { name: /save my area/i }).click();
  await expect(page.getByText(/^saved\.$/i)).toBeVisible({ timeout: 20_000 });

  await page.reload();
  await hydrated(page.locator("main"));

  await expect(
    page.getByLabel(/town or city/i),
    "it came back from the database rather than from component state",
  ).toHaveValue("Cypress", { timeout: 20_000 });
  await expect(page.getByLabel(/zip code/i)).toHaveValue("77429");

  // ---- put the shared member back ---------------------------------------------
  // nearby-alerts.spec moved a demo member 145 miles and left her there, and membership.spec then
  // failed somewhere unrelated. A stated area changes which adverts and announcements this member
  // matches, so leaving one set would make the targeting assertions elsewhere depend on run order.
  await page.getByRole("button", { name: /remove my area/i }).click();
  await expect(page.getByText(/^saved\.$/i)).toBeVisible({ timeout: 20_000 });

  await page.reload();
  await hydrated(page.locator("main"));
  await expect(
    page.getByLabel(/town or city/i),
    "the shared demo member is back to having no stated area, asserted rather than hoped for",
  ).toHaveValue("", { timeout: 20_000 });
});

test("the Content & Marketing tabs each load their own list", async ({ page }) => {
  await signIn(page, ADMIN);
  await page.goto("/admin/content");
  // No <main> in the admin layout, so this anchors on a control AdminContent itself renders.
  await hydrated(page.getByRole("button", { name: /^announcements$/i }));

  // Three RPCs behind three tabs. Each one is granted to `authenticated` and gated on
  // app.is_admin(), so a wrong grant shows up here as a tab that never stops loading.
  await page.getByRole("button", { name: /^events$/i }).click();
  await expect(
    page.getByRole("heading", { name: /^new event$/i }),
    "the Events tab renders its form, so admin_events answered",
  ).toBeVisible({ timeout: 20_000 });

  // Section 2's promotional fields are reachable ONLY from here -- a CHECK on the table keys them
  // to is_official, which create_event never sets. The note saying so has to be on the screen,
  // because an admin cannot otherwise tell why a member's event has no organiser field.
  await expect(page.getByText(/an event created here is official/i)).toBeVisible();

  // And the asymmetry a reviewer should be able to see without reading a migration.
  await expect(page.getByText(/targeting an event does not hide it/i)).toBeVisible();

  await page.getByRole("button", { name: /^campaigns$/i }).click();
  await expect(
    page.getByRole("button", { name: /show archived/i }),
    "the Campaigns tab renders, so admin_campaigns answered",
  ).toBeVisible({ timeout: 20_000 });

  await page.getByRole("button", { name: /^announcements$/i }).click();
  await expect(page.getByRole("heading", { name: /^new announcement$/i })).toBeVisible({
    timeout: 20_000,
  });

  // The targeting editor says what an empty list MEANS. "All Members" is the absence of rows in
  // the database, so a blank box would reasonably read as "nobody yet".
  await expect(
    page.getByText(/no places chosen, so this reaches every member/i),
    "the empty targeting state is spelled out rather than left blank",
  ).toBeVisible();
});

test("opening an event counts a view, which the admin report can see", async ({ page }) => {
  // THE LOOP THIS CLOSES. record_event_view() and event_daily_stats shipped with nothing able to
  // call them, so admin_event_report's views column was structurally stuck at zero. The event page
  // is the caller. Nothing else in this project can prove that end to end: the counter fires from a
  // browser effect on purpose -- Next prefetches routes on hover and on scroll, and counting during
  // the server render would count people who never opened it -- so only a real browser exercises it.
  const marker = `Counted run ${Date.now().toString(36)}`;

  // A member posts an event from the feed, which is the normal way one appears.
  await signIn(page, MEMBER);
  await page.goto("/community");
  await hydrated(page.locator("main"));
  await page.getByRole("tab", { name: /^events$|^eventos$/i }).click();

  await page.getByRole("button", { name: /post an event|publicar un evento/i }).click();
  await page.getByLabel(/what is it|qué es/i).pressSequentially(marker);

  const when = new Date(Date.now() + 4 * 24 * 60 * 60 * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  await page
    .locator('input[type="datetime-local"]')
    .fill(`${when.getFullYear()}-${pad(when.getMonth() + 1)}-${pad(when.getDate())}T09:00`);
  await page
    .getByLabel(/where to meet|dónde encontrarse/i)
    .pressSequentially("The usual gravel lot");
  await page.getByRole("button", { name: /post it|^publicar$/i }).click();

  const card = page.locator("li").filter({ hasText: marker }).first();
  await expect(card, "the event is published and listed").toBeVisible({ timeout: 20_000 });

  // WAIT FOR THE COUNT TO ACTUALLY GO, rather than sleeping and hoping.
  //
  // The view is recorded by a client effect calling a server action, which Next sends as a POST to
  // the route's own URL. The first version of this test asserted the count straight after the
  // heading appeared and read zero: the effect had not run yet, and the next step cleared the
  // cookies, so by the time the action reached the server there was no session and it correctly
  // counted nothing. Waiting on the response makes the test deterministic AND asserts the action
  // fires at all -- a counter that never calls anything would otherwise look like a counter that
  // simply measured zero.
  const viewRecorded = page.waitForResponse(
    (r) => r.request().method() === "POST" && /\/events\/[0-9a-f-]{36}/.test(r.url()),
    { timeout: 20_000 },
  );

  // The title is the link. A card that nothing links from is how /welcome stayed unreachable for
  // two days, so this click is also the assertion that the link exists.
  await card.getByRole("link", { name: marker }).click();
  await page.waitForURL(/\/events\/[0-9a-f-]{36}/, { timeout: 20_000 });

  await expect(
    page.getByRole("heading", { name: marker, level: 1 }),
    "the event has its own page, reached from the list",
  ).toBeVisible({ timeout: 20_000 });
  await expect(page.getByText(/the usual gravel lot/i)).toBeVisible();

  await viewRecorded;

  // ---- and the view reached the database ---------------------------------------
  // The effect fires after mount, so give the action a moment before asking the report. Asserted
  // through the ADMIN REPORT rather than by reading the table, because that report is the thing
  // that was broken: a column that could never move.
  await signOut(page);
  await signIn(page, ADMIN);
  await page.goto("/admin/content");
  await hydrated(page.getByRole("button", { name: /^announcements$/i }));
  await page.getByRole("button", { name: /^events$/i }).click();

  // THE ASSERTION THIS WHOLE TEST IS FOR. Not "the page rendered" -- that is two lines up -- but
  // that opening it moved a number the admin can see. Before the event page existed this count was
  // structurally stuck at zero, and a report of zeros reads as "nobody looks at our events" rather
  // than "nothing is counting".
  await expect(
    page.getByText(/how events are doing/i),
    "the event report is on screen, so admin_event_report is finally called by something",
  ).toBeVisible({ timeout: 20_000 });

  await expect(
    page.locator("li").filter({ hasText: marker }).filter({ hasText: /views/i }).first(),
    "the event just opened shows at least one view",
  ).toContainText(/[1-9][0-9]* views/, { timeout: 20_000 });
});

test("the account screen works for an ADMIN, not just a member", async ({ page }) => {
  /**
   * THE REGRESSION THIS GUARDS, and why nothing caught it for weeks.
   *
   * `profiles_self_read` is `user_id = auth.uid() OR app.is_admin()`, so an admin reads EVERY
   * profile row. /account, /account/location and /account/notifications all selected from
   * `profiles` with no user_id filter and called maybeSingle(), which fails on more than one row.
   * So those three screens were broken for exactly one person -- the owner -- and worked for
   * everybody else. It also got worse as the membership grew: at one member it returned one row.
   *
   * Every pgTAP suite and every other browser test signs in as an ordinary member. The whole
   * class of "works unless you are an admin" was untestable by construction, which is the actual
   * lesson: the admin is a different RLS subject, so the admin has to open the member screens too.
   */
  await signIn(page, ADMIN);

  // --- /account ---------------------------------------------------------------
  await page.goto("/account");
  await hydrated(page.locator("main"));

  await expect(
    page.getByText(/could not load your details/i),
    "no load-failure banner: the select returns one row, not every row",
  ).toHaveCount(0, { timeout: 20_000 });

  const name = page.getByLabel(/display name/i);
  await expect(name, "the form renders").toBeVisible({ timeout: 20_000 });

  // Remember what was there so this suite puts the shared admin back.
  const original = (await name.inputValue()) ?? "";
  const marker = `Admin ${Date.now().toString(36)}`;

  await name.fill("");
  await name.pressSequentially(marker);
  await page.getByRole("button", { name: /save changes|guardar/i }).click();

  // A ZERO-ROW UPDATE USED TO REPORT SUCCESS. Reloading is what tells the two apart.
  await page.reload();
  await hydrated(page.locator("main"));
  await expect(
    page.getByLabel(/display name/i),
    "the name actually persisted, rather than the save reporting a row it never wrote",
  ).toHaveValue(marker, { timeout: 20_000 });

  // --- the other two screens with the same bug --------------------------------
  await page.goto("/account/location");
  await hydrated(page.locator("main"));
  await expect(
    page.getByLabel(/town or city/i),
    "/account/location gets past Loading for an admin too",
  ).toBeVisible({ timeout: 20_000 });

  await page.goto("/account/notifications");
  await hydrated(page.locator("main"));
  await expect(
    page.getByText(/could not|no se pudo/i),
    "/account/notifications loads for an admin without an error",
  ).toHaveCount(0, { timeout: 20_000 });

  // --- put the shared admin back ----------------------------------------------
  await page.goto("/account");
  await hydrated(page.locator("main"));
  const restore = page.getByLabel(/display name/i);
  await restore.fill("");
  if (original) await restore.pressSequentially(original);
  await page.getByRole("button", { name: /save changes|guardar/i }).click();

  await page.reload();
  await hydrated(page.locator("main"));
  await expect(
    page.getByLabel(/display name/i),
    "the admin's name is back to what this test found, asserted rather than hoped for",
  ).toHaveValue(original, { timeout: 20_000 });
});

test("a member cannot reach Content & Marketing", async ({ page }) => {
  await signIn(page, MEMBER);
  await page.goto("/admin/content");

  // The admin layout decides what renders; every RPC behind it checks app.is_admin() for itself,
  // so this is presentation rather than permission. Asserted anyway: the layout gate is the thing
  // that stops a member seeing the words an admin is drafting.
  await expect(
    page.getByRole("heading", { name: /content & marketing/i }),
    "a member gets the admin sign-in gate instead of the screen",
  ).toHaveCount(0, { timeout: 20_000 });
});
