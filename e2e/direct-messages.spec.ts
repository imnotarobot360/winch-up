import { expect, test, type Page } from "@playwright/test";

/**
 * Two members having a conversation, in two real browsers.
 *
 * pgTAP proves the access rule -- who may start a thread, who may continue one, what a payload carries.
 * What it cannot prove is that the two halves meet: that something one member types appears on another
 * member's screen, with an unread badge, and that a reply comes back. Those are two sessions, and a
 * single-session test would pass with the whole receiving side broken.
 *
 * ONE PROJECT, because it writes. The suite drives the same four demo accounts everywhere, and four
 * projects would mean four conversations racing each other through one pair of inboxes.
 */

const PASSWORD = "recovery-demo-2026";
const MIKE = { email: "mike@winchup.test", password: PASSWORD };
const ROSA = { email: "rosa@winchup.test", password: PASSWORD };

/** Rosa, from supabase/seeds/demo.sql. */
const ROSA_ID = "00000000-0000-4000-8000-000000000003";

async function hydrated(page: Page) {
  await page
    .locator("form")
    .first()
    .evaluate(
      (el) =>
        new Promise<void>((resolve) => {
          const on = () => Object.keys(el).some((k) => k.startsWith("__react"));
          if (on()) return resolve();
          const timer = setInterval(() => {
            if (on()) {
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

test.describe.configure({ mode: "serial" });

test.beforeEach(({}, testInfo) => {
  test.skip(testInfo.project.name !== "android", "Writes real conversations: one project only");
});

test("a member messages another, who gets it, reads it and replies", async ({ browser }) => {
  const note = `strap ${Date.now().toString(36)}`;
  const reply = `reply ${Date.now().toString(36)}`;

  const mikeContext = await browser.newContext();
  const mike = await mikeContext.newPage();
  await signIn(mike, MIKE);

  // ---- the Message button decides for itself whether to exist -----------
  //
  // It renders nothing until dm_can_message() answers, so this waits for the button rather than
  // asserting on the first paint. A getByRole that resolved instantly here would be finding a button
  // the server has not agreed to yet.
  await mike.goto(`/members/${ROSA_ID}`);

  const messageButton = mike.getByRole("button", { name: /^message /i });
  await expect(
    messageButton,
    "the profile offers to message a member who allows it",
  ).toBeVisible({ timeout: 20_000 });

  await messageButton.click();
  await mike.getByRole("textbox").last().pressSequentially(note);
  await mike.getByRole("button", { name: /^send$|^enviar$/i }).click();

  // Sending the first message opens the conversation and goes straight to it. There is no
  // confirmation screen on purpose -- the thread is the confirmation.
  await mike.waitForURL(/\/messages\/[0-9a-f-]{36}$/, { timeout: 20_000 });
  await expect(mike.getByText(note), "and it is in the thread").toBeVisible({ timeout: 20_000 });

  // ---- the other side ---------------------------------------------------
  //
  // A separate context, not a second tab: the whole question is whether this reaches a DIFFERENT
  // session, and sharing cookies would answer a question nobody asked.
  const rosaContext = await browser.newContext();
  const rosa = await rosaContext.newPage();
  await signIn(rosa, ROSA);

  await rosa.goto("/messages");

  const row = rosa.locator("li").filter({ hasText: note }).first();
  await expect(row, "it arrives in the other member's inbox").toBeVisible({ timeout: 20_000 });
  await expect(row, "with an unread badge, because she has not opened it").toContainText("1");

  await row.click();
  await rosa.waitForURL(/\/messages\/[0-9a-f-]{36}$/, { timeout: 20_000 });
  await expect(rosa.getByText(note), "and the message is there").toBeVisible({ timeout: 20_000 });

  // ---- a reply ----------------------------------------------------------
  await rosa.getByRole("textbox").last().pressSequentially(reply);
  await rosa.getByRole("button", { name: /^send$|^enviar$/i }).click();
  await expect(rosa.getByText(reply), "she can reply").toBeVisible({ timeout: 20_000 });

  // Back on the first member's screen, without a reload: the thread polls every fifteen seconds, so
  // this is the poll being asserted as well as the reply. The timeout is deliberately longer than the
  // interval -- a 15s assertion against a 15s poll is a coin toss.
  await expect(
    mike.getByText(reply),
    "and it reaches the first member on the next poll, with no reload",
  ).toBeVisible({ timeout: 40_000 });

  // ---- reading it clears the badge --------------------------------------
  await rosa.goto("/messages");
  const readRow = rosa.locator("li").filter({ hasText: reply }).first();
  await expect(readRow, "the conversation is still in her inbox").toBeVisible({ timeout: 20_000 });
  await expect(
    readRow,
    "and her own last message is prefixed, so it does not read as if he went quiet",
  ).toContainText(/you:|usted:/i);

  // ---- what the other member cannot do ----------------------------------
  //
  // The thread id is in the URL and is NOT a capability. A member handed somebody else's gets the same
  // not_found as one that never existed -- so a forwarded link reveals nothing, not even that it was
  // real. That is the opposite of /r/[token], where the token IS the key.
  const stranger = await browser.newContext();
  const page = await stranger.newPage();
  await signIn(page, { email: "pending@winchup.test", password: PASSWORD });

  const threadUrl = new URL(mike.url()).pathname;
  await page.goto(threadUrl);
  await expect(
    page.getByText(/that conversation isn't there|esa conversación no existe/i),
    "a third member handed the link gets nothing",
  ).toBeVisible({ timeout: 20_000 });

  await mikeContext.close();
  await rosaContext.close();
  await stranger.close();
});
