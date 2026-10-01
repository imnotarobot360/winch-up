import { expect, test, type Page } from "@playwright/test";

/**
 * The member directory, on every shape of screen.
 *
 * The owner's spec asks for this explicitly (§7): every active member appears, every member can open
 * another's profile, approved vehicle information shows, phone numbers and email addresses stay
 * protected, exact coordinates cannot be retrieved, and the whole thing is checked on desktop,
 * iPhone and Android. So unlike most specs here, the read-only half runs on ALL FOUR projects --
 * android and desktop on Chromium, iphone and tablet on real WebKit -- because it writes nothing and
 * the question being asked is partly a layout question.
 *
 * WHAT THIS IS REALLY GUARDING
 *
 * 20261001001100 removed two consent gates from a directory. pgTAP proves the SQL: who is listed,
 * what a row carries, that a suspended member is gone. What it cannot prove is that the page a member
 * actually looks at did not acquire a phone number on the way out of the database -- a server
 * component could add one from any other source, and nothing in the RPC tests would notice.
 *
 * So the assertions here are about the RENDERED TEXT: no phone, no email, no coordinates anywhere on
 * the page. That is a different question from the RPC one, and it is the one a member is exposed to.
 */

const PASSWORD = "recovery-demo-2026";
const MIKE = { email: "mike@winchup.test", password: PASSWORD };
const ADMIN = { email: "admin@winchup.test", password: PASSWORD };

/**
 * The admin account's id, from supabase/seeds/demo.sql.
 *
 * Used because it is the one seeded profile with NO responders row -- admin never signed up as a
 * volunteer. That is the exact case the old inner join dropped, and most of the membership looks
 * like it: app.ensure_recovery_profile() runs only when somebody turns availability on. Opening this
 * profile is the difference between "every member appears" being true and being plausibly false.
 */
const NO_RIG_MEMBER = "00000000-0000-4000-8000-000000000001";

/**
 * Somebody else to report, and it cannot be the one above.
 *
 * NO_RIG_MEMBER is the admin's own account, and admin_suspend_member() refuses
 * cannot_suspend_self -- so the first version of this test had the admin reporting themselves,
 * suspending themselves, and failing on an assertion about the Lift button with no sign that the
 * refusal was the product being right. The guard exists because an admin who suspends themselves
 * is out of the directory while still able to undo it, which is a half-state for no gain.
 *
 * pending@winchup.test from the demo seed. Suspending them is restored at the end, and
 * e2e/global-setup.ts lifts any suspension on a demo account before every run as well -- because
 * a run that dies between the suspend and the restore would otherwise leave a shared account
 * invisible to every other spec.
 */
const SUSPEND_TARGET = "00000000-0000-4000-8000-000000000004";

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

test.describe("the member directory", () => {
  test.describe.configure({ mode: "serial" });

  test("lists members who never opted into anything, and still hides their details", async ({
    page,
  }) => {
    await signIn(page, MIKE);
    await page.goto("/members");

    // Rosa is a seeded volunteer two counties over. Present whatever her switches say -- which is
    // the change: she is listed because she is a member, not because she opted in twice.
    const rosa = page.locator("li").filter({ hasText: /Rosa/ }).first();
    await expect(rosa, "a seeded member is in the directory").toBeVisible({ timeout: 20_000 });

    // More than one, so a directory that happened to contain exactly one row would not pass.
    await expect(
      page.locator("li").filter({ hasText: /\d+\s*mi\b|milla/i }),
      "and so is more than one person",
    ).not.toHaveCount(0);

    // ---- search runs on the server now ----------------------------------
    //
    // It used to filter the hundred fetched rows in the browser, which searched a page of the
    // membership while appearing to search the directory. Typed rather than filled: fill() clears a
    // sibling field on WebKit, which is a trap this suite has hit before.
    const search = page.getByRole("searchbox").first();
    await search.pressSequentially("rosa");
    await expect(rosa, "searching by name finds her").toBeVisible({ timeout: 20_000 });

    // THE WILDCARD ESCAPE, end to end. app.like_contains escapes _ and %, so a member typing an
    // underscore gets the names that contain one. Without it, "_" is a single-character wildcard and
    // the search box becomes a way to page through the whole membership one pattern at a time -- and
    // it would look like a working search the entire time.
    await search.fill("");
    await search.pressSequentially("_");
    await expect(
      page.getByText(/nobody matches that|nadie coincide/i),
      "an underscore is a character, not a wildcard",
    ).toBeVisible({ timeout: 20_000 });
  });

  test("opens the profile of a member who never signed up as a volunteer", async ({ page }) => {
    await signIn(page, MIKE);
    await page.goto(`/members/${NO_RIG_MEMBER}`);

    // Not notFound(). Before the left join this was a 404 for most of the membership.
    await expect(
      page.getByRole("heading", { level: 1 }),
      "a member with no responders row has a profile that opens",
    ).toBeVisible({ timeout: 20_000 });

    await expect(
      page.getByText(/recoveries they came out to|rescates a los que/i),
      "with their real numbers rather than an error",
    ).toBeVisible();

    // ---- what must NOT be on the page -----------------------------------
    //
    // Read as text, because that is what a member is exposed to. The RPC tests assert the same thing
    // about the jsonb; this asserts it about the page, and a server component could have added a
    // phone number from somewhere else entirely without any RPC test noticing.
    const body = (await page.locator("main").innerText()).replace(/\s+/g, " ");

    expect(body, "no phone number anywhere on a member's profile").not.toMatch(
      /\+1\s?\d{10}|\(\d{3}\)\s?\d{3}-?\d{4}|\b\d{3}-\d{3}-\d{4}\b/,
    );
    expect(body, "no email address either").not.toMatch(/[\w.+-]+@[\w-]+\.[\w.]+/);

    // Coordinates. Two decimal places is already a street; this looks for any decimal pair at all,
    // and for the raw latitude band Texas sits in. A directory that leaks a position is the one
    // failure in here that puts somebody's house on a map.
    expect(body, "and nothing that could be a coordinate pair").not.toMatch(
      /-?\d{1,3}\.\d{3,},\s*-?\d{1,3}\.\d{3,}/,
    );
    expect(body, "nor a bare latitude").not.toMatch(/\b2[6-9]\.\d{4,}|\b3[0-6]\.\d{4,}/);

    // The two things a member CAN do about another member (§6).
    await expect(page.getByRole("button", { name: /report this member|reportar a/i })).toBeVisible();
    await expect(page.getByRole("button", { name: /block them|bloquearlo/i })).toBeVisible();
  });
});

/**
 * Reporting somebody, and what an admin can do about it.
 *
 * ONE PROJECT, because this writes: a report row, then a suspension that takes a shared demo account
 * out of the directory. Four projects would mean four reports about the same member and four
 * suspensions racing each other, and the suite drives these same accounts everywhere.
 *
 * It restores at the end, asserted rather than hoped for. A suspended demo member is not a state to
 * leave behind -- membership.spec and nearby-alerts.spec both expect these accounts to be findable,
 * and a cleanup wrapped in a catch that quietly does nothing is how this suite broke itself before.
 */
test.describe("reporting a member", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeEach(({}, testInfo) => {
    test.skip(testInfo.project.name !== "android", "Writes real reports: one project only");
  });

  test("a report reaches an admin, who can suspend and then lift it", async ({ browser }) => {
    const memberContext = await browser.newContext();
    const member = await memberContext.newPage();
    await signIn(member, MIKE);

    // ---- the report -----------------------------------------------------
    await member.goto(`/members/${SUSPEND_TARGET}`);
    await member.getByRole("button", { name: /report this member|reportar a/i }).click();
    await member.getByRole("radio", { name: /harassment|acoso/i }).first().check();
    await member.getByRole("button", { name: /send report|enviar reporte/i }).click();

    await expect(
      member.getByText(/an admin will look at this|un administrador lo revisará/i),
      "the member is told what happens next, rather than the button going quiet",
    ).toBeVisible({ timeout: 20_000 });

    // ---- the queue ------------------------------------------------------
    const adminContext = await browser.newContext();
    const admin = await adminContext.newPage();
    await signIn(admin, ADMIN);
    await admin.goto("/moderation");

    const queue = admin
      .locator("section")
      .filter({ hasText: /reported members|miembros reportados/i });

    // ONE MEMBER'S CARD, not the section. The queue holds everybody awaiting a decision, so
    // "the suspend button" is as many buttons as there are reported members -- which is how this
    // first failed, on a local database that still had an earlier report in it. Trey is the
    // seeded display name for SUSPEND_TARGET.
    const card = queue.locator("li").filter({ hasText: /Trey/ }).first();
    await expect(queue, "the section is there at all").toBeVisible({ timeout: 20_000 });
    await expect(card, "with this report in front of an admin").toBeVisible({ timeout: 20_000 });

    // A REPORTED MEMBER IS NOT IN THE CONTENT QUEUE. Adding 'member' to content_reports put people
    // into the queue built for posts, rendering a raw translation key and offering "Put it back" for
    // a human -- a button that would have looked up a post id that is actually a user id and done
    // nothing, silently. 20261001001500 is the one line that fixed it.
    await expect(
      admin.getByText("moderation.kind.member"),
      "and not in the content queue, where it would render as a raw key",
    ).toHaveCount(0);

    // ---- the suspension -------------------------------------------------
    await card.getByRole("button", { name: /suspend this account|suspender esta cuenta/i }).click();
    await card.getByRole("textbox").first().pressSequentially("e2e suspension check");
    await card.getByRole("button", { name: /^suspend$|^suspender$/i }).click();

    await expect(
      card.getByRole("button", { name: /lift the suspension|levantar la suspensión/i }),
      "a suspended member stays listed, which is the only route back",
    ).toBeVisible({ timeout: 20_000 });

    // The member is gone from the community. Checked from the OTHER account, because the whole point
    // is what everybody else can see.
    await member.goto(`/members/${SUSPEND_TARGET}`);
    await expect(
      member.getByText(/we couldn't find that|no encontramos/i),
      "and their profile stops opening for everybody else",
    ).toBeVisible({ timeout: 20_000 });

    // ---- and back again -------------------------------------------------
    await admin.goto("/moderation");
    const restored = admin
      .locator("section")
      .filter({ hasText: /reported members|miembros reportados/i })
      .locator("li")
      .filter({ hasText: /Trey/ })
      .first();
    await restored
      .getByRole("button", { name: /lift the suspension|levantar la suspensión/i })
      .click();

    // AND THEN THEY LEAVE THE QUEUE, which is right and was not what this first asserted.
    //
    // Suspending closes their open reports, so once the suspension is lifted there is nothing
    // pending about them and nothing being served -- and this screen is people under or awaiting a
    // decision. The first version expected the Suspend button to come back, which would mean a
    // member who was looked at once stays on the moderation screen forever.
    await expect(
      restored,
      "with the decision made and lifted, they are not awaiting one any more",
    ).toHaveCount(0, { timeout: 20_000 });

    await member.goto(`/members/${SUSPEND_TARGET}`);
    await expect(
      member.getByRole("heading", { level: 1 }),
      "and the member is a member again, with everything they had",
    ).toBeVisible({ timeout: 20_000 });

    await memberContext.close();
    await adminContext.close();
  });
});
