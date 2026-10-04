import { expect, test, type Locator, type Page } from "@playwright/test";

/**
 * A member's photograph.
 *
 * `profiles.avatar_path` had existed since phase 3 with nothing able to write it: the column was
 * granted for UPDATE all along, and there was no bucket, no upload route and no renderer, so the
 * Avatar component drew initials and said so in a comment. The owner asked for the picture on
 * 2026-10-04.
 *
 * THIS IS THE ONLY PLACE THE FEATURE CAN BE CHECKED. The dev server in the sandbox it was built in
 * cannot render /account at all -- it fails to fetch Google Fonts over TLS, 500s on /_next/image,
 * and the account form never hydrates. That was proven to be the environment rather than the
 * change by stashing the whole feature and watching /account stay stuck on "Loading your
 * account...". Playwright runs `next build && next start`, which works.
 *
 * One project, like every suite that writes real rows: this uploads a real object to storage and
 * points a shared demo account at it, so it puts the account back at the end.
 */

const MEMBER = { email: "mike@winchup.test", password: "recovery-demo-2026" };
const FIXTURE = "e2e/fixtures/avatar.jpg";

test.describe.configure({ mode: "serial" });

/**
 * Is there a Storage service to upload to?
 *
 * The no-Docker local stack is a gateway, PostgREST and Postgres. It answers 501 for
 * /storage/v1 and says so: "storage-api is not running locally - needs Docker or a cloud
 * project." So the upload half of this feature CANNOT run on a developer machine using that
 * stack, and a test that fails there teaches nobody anything.
 *
 * CI is different -- its "Start this runner's own Supabase" step runs the full Docker stack,
 * storage included -- so this is a skip that disappears exactly where the check is possible.
 * Probed rather than keyed off an env var, because the question is whether the service ANSWERS,
 * not whether somebody remembered to set a flag.
 */
let storageAvailable: boolean | null = null;

async function hasStorage(): Promise<boolean> {
  if (storageAvailable !== null) return storageAvailable;

  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!base) {
    storageAvailable = false;
    return storageAvailable;
  }

  try {
    const response = await fetch(`${base}/storage/v1/bucket`, {
      headers: { apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "" },
      signal: AbortSignal.timeout(5000),
    });
    // 501 is the local gateway saying it does not run storage-api. 400/401/403 all mean a real
    // service answered and merely refused this request, which is enough.
    storageAvailable = response.status !== 501;
  } catch {
    storageAvailable = false;
  }

  return storageAvailable;
}

test.beforeEach(({}, testInfo) => {
  test.skip(
    testInfo.project.name !== "android",
    "Uploads a real object and edits a shared profile: one project only",
  );
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
  await page.getByLabel(/email|correo/i).pressSequentially(MEMBER.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(MEMBER.password);
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"), { timeout: 20_000 });
}

test("a member can add a photograph, and it survives a reload", async ({ page }) => {
  test.skip(!(await hasStorage()), "No Storage service on this stack -- see hasStorage() above");

  await signIn(page);
  await page.goto("/account");
  await hydrated(page.locator("main"));

  const add = page.getByRole("button", { name: /add a photo|change photo/i });
  await expect(add, "the upload control is on the account screen").toBeVisible({
    timeout: 20_000,
  });

  // The input is hidden behind that button, so set it directly rather than opening a file dialog
  // the harness cannot drive.
  await page.locator('input[type="file"]').setInputFiles(FIXTURE);

  // THE ASSERTION THAT MATTERS IS AFTER A RELOAD, not before it. The component shows the chosen
  // file immediately from a local object URL, so a picture appearing proves only that the browser
  // read the file. Only a reload proves the object reached storage AND profiles.avatar_path was
  // written AND the server could mint a signed URL for it -- three things, one check.
  await expect(
    page.getByRole("button", { name: /change photo/i }),
    "the control switches to Change, so the upload and the profile write both landed",
  ).toBeVisible({ timeout: 30_000 });

  await page.reload();
  await hydrated(page.locator("main"));

  const img = page.locator("main img").first();
  await expect(img, "a photograph renders after a reload, from a server-signed URL").toBeVisible({
    timeout: 20_000,
  });

  const src = await img.getAttribute("src");
  expect(src, "the src is a signed Storage URL, never a raw path").toMatch(/\/storage\/v1\//);
  expect(src, "and it is signed -- the bucket is private and a bare path renders nothing").toMatch(
    /token=|signature=/,
  );

  // --- put the shared demo member back -----------------------------------------
  // Every run drives the same four accounts. A photograph left behind would change what the
  // members list and the DM screens render for everybody else's runs.
  await page.getByRole("button", { name: /remove photo/i }).click();

  await page.reload();
  await hydrated(page.locator("main"));
  await expect(
    page.getByRole("button", { name: /add a photo/i }),
    "the photo is removed again, asserted rather than hoped for",
  ).toBeVisible({ timeout: 20_000 });
});

test("the account screen falls back to initials with no photograph", async ({ page }) => {
  await signIn(page);
  await page.goto("/account");
  await hydrated(page.locator("main"));

  // The control for the test above. Without this, "a photograph renders" would also pass against a
  // screen that rendered an <img> for everybody, photograph or not.
  await expect(
    page.getByRole("button", { name: /add a photo/i }),
    "with no photograph the control offers to add one",
  ).toBeVisible({ timeout: 20_000 });

  await expect(
    page.locator("main img"),
    "and no image is rendered -- initials are a span, not a broken <img>",
  ).toHaveCount(0);
});
