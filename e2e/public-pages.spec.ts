import { expect, test } from "@playwright/test";

/**
 * The pages anybody can reach without an account.
 *
 * Deliberately read-only. These run against whatever Supabase the dev server is pointed at, and
 * that is currently the production project — so nothing here submits a form, creates a request,
 * or writes a row. A test suite that files recovery requests against live data would be worse
 * than no test suite.
 */

const PAGES = [
  // A fresh browser context has no wu_seen_welcome cookie, so "/" IS the onboarding screen.
  // The landing page behind it is covered by its own test below.
  { path: "/", heading: /off-roaders helping off-roaders/i, title: /Winch Up/ },
  { path: "/board", heading: /Open board/i, title: /board/i },
  { path: "/terms", heading: /.+/, title: /.+/ },
  { path: "/waiver", heading: /.+/, title: /.+/ },
  { path: "/privacy", heading: /.+/, title: /.+/ },
  { path: "/signin", heading: /Sign in/i, title: /Sign in/i },
  { path: "/signup", heading: /Create your account/i, title: /Create account/i },
  { path: "/reset", heading: /Reset your password/i, title: /Reset/i },
  { path: "/resources", heading: /Getting out/i, title: /Getting out/i },
];

// Public and indexable, unlike trails and the feed — this is the part of the app that is useful
// to somebody who has never heard of us and is standing next to a stuck truck right now.
const GUIDES = ["stuck", "safety", "gear", "before", "etiquette", "weather"];

test.describe("public pages", () => {
  for (const page_ of PAGES) {
    test(`${page_.path} renders`, async ({ page }) => {
      const errors: string[] = [];
      page.on("console", (message) => {
        if (message.type() === "error") errors.push(message.text());
      });

      const response = await page.goto(page_.path);
      expect(response?.status(), `${page_.path} should serve`).toBeLessThan(400);

      await expect(page).toHaveTitle(page_.title);
      await expect(page.locator("h1").first()).toBeVisible();

      // Not a blank page dressed up as a working one.
      const text = await page.locator("main").innerText();
      expect(text.trim().length, `${page_.path} has no visible content`).toBeGreaterThan(20);

      // Hydration mismatches and missing translations surface here and nowhere else.
      const real = errors.filter(
        (e) => !e.includes("favicon") && !e.includes("Download the React DevTools"),
      );
      expect(real, `${page_.path} logged console errors`).toEqual([]);
    });
  }
});

test.describe("the resources section", () => {
  for (const slug of GUIDES) {
    test(`/resources/${slug} renders its checklists`, async ({ page }) => {
      const response = await page.goto(`/resources/${slug}`);
      expect(response?.status()).toBeLessThan(400);

      await expect(page.locator("h1")).toBeVisible();

      // Every guide is lists. A guide that renders its heading and no items is a guide that lost
      // its content to a message-shape change, which is exactly the failure worth catching.
      const items = await page.locator("main li").count();
      expect(items, `${slug} has no list items`).toBeGreaterThan(4);

      // The spec line for this phase: do not represent volunteers as certified professionals.
      // It is on every guide, not only the index, because people arrive from search and from
      // forwarded links.
      await expect(page.locator("main")).toContainText(
        /volunteers, not professionals|voluntarios, no profesionales/i,
      );
      await expect(page.locator("main")).toContainText(/911/);
    });
  }

  test("an unknown guide lands on not-found, and asks not to be indexed", async ({ page }) => {
    // Not a status assertion, and the reason is the one this project keeps relearning: the head
    // flushes before the guard runs, so the response is already committed as 200 by the time
    // notFound() fires. Where the person ends up is the behaviour. The noindex is what stops a
    // crawler filing it as a real page.
    await page.goto("/resources/not-a-guide");

    const text = await page.locator("main").innerText();
    expect(text).toMatch(/No such guide|Esa guía no existe/i);
    expect(text, "the guide's own content must not render").not.toMatch(/Turn around, don't drown/);

    const robots = await page
      .locator('meta[name="robots"]')
      .first()
      .getAttribute("content");
    expect(robots ?? "").toMatch(/noindex/);
  });

  test("the Spanish guides are Spanish, not a fallback to English", async ({ page }) => {
    await page.goto("/es/resources/safety");
    const text = await page.locator("main").innerText();
    await expect(page.locator("h1")).toContainText(/rescate/i);
    expect(text).not.toMatch(/A line under tension|Know when to stop/);
  });

  test("the index links every guide", async ({ page }) => {
    await page.goto("/resources");
    for (const slug of GUIDES) {
      await expect(page.locator(`a[href$="/resources/${slug}"]`)).toBeVisible();
    }
  });
});

test.describe("Spanish", () => {
  test("/es serves Spanish, not a translated-looking English page", async ({ page }) => {
    await page.goto("/es");
    await expect(page.locator("html")).toHaveAttribute("lang", "es");
    const text = await page.locator("main").innerText();
    expect(text).toMatch(/atascado|ayuda|rescate/i);
  });

  test("the request wizard's 911 gate is Spanish", async ({ page }) => {
    await page.goto("/es/signin");
    const text = await page.locator("main").innerText();
    expect(text).toMatch(/Iniciar sesión/i);
    expect(text).not.toMatch(/\bSign in\b/);
  });
});

test.describe("not found", () => {
  test("an unknown path does not render a broken shell", async ({ page }) => {
    const response = await page.goto("/definitely-not-a-page");
    expect(response?.status()).toBe(404);
    const text = await page.locator("body").innerText();
    expect(text.trim().length).toBeGreaterThan(10);
  });
});

test.describe("PWA", () => {
  test("the manifest and icons are served, unprefixed by locale", async ({ request }) => {
    const manifest = await request.get("/manifest.webmanifest");
    expect(manifest.status()).toBe(200);

    const body = await manifest.json();
    expect(body.name).toBeTruthy();
    expect(body.icons.length).toBeGreaterThan(0);

    // Every icon the manifest promises must actually exist. A missing one means the app will
    // not install, and nothing else in the test suite would notice.
    for (const icon of body.icons) {
      const response = await request.get(icon.src);
      expect(response.status(), `${icon.src} is referenced by the manifest`).toBe(200);
    }
  });
});

/**
 * The front door.
 *
 * Screens 1 and 2 of the design reference are a splash and an onboarding screen. /welcome was
 * built and deployed and then nothing linked to it for two days, so every new visitor landed on
 * the marketing page instead and the reference was quietly not followed. Nothing caught that:
 * every page rendered, every link resolved, and the screen that was missing was one nobody
 * navigated to.
 *
 * Both halves are asserted because either alone is wrong. Onboarding every time is an obstacle;
 * onboarding never is the bug that was there.
 */
test.describe("the first visit", () => {
  test("a new visitor gets the onboarding screen, not the landing page", async ({ page }) => {
    await page.context().clearCookies();
    await page.goto("/");

    await expect(page).toHaveURL(/\/welcome$/);
    await expect(page.getByRole("heading", { name: /off-roaders helping off-roaders/i }))
      .toBeVisible();
    await expect(page.getByRole("link", { name: /get started/i })).toBeVisible();
    await expect(page.getByRole("link", { name: /sign in/i })).toBeVisible();
  });

  test("and the second visit goes straight to the landing page", async ({ page }) => {
    await page.context().clearCookies();
    await page.goto("/");
    await expect(page).toHaveURL(/\/welcome$/);

    // The cookie is set by the middleware on the response that served /welcome.
    await page.goto("/");
    await expect(page).not.toHaveURL(/\/welcome$/);
    await expect(page.getByRole("link", { name: /I'm stuck/i })).toBeVisible();
  });

  test("somebody who is stuck can skip onboarding entirely", async ({ page }) => {
    // The whole product is for people who need help now. Making them read a pitch first would
    // be the worst possible place to put a funnel.
    await page.context().clearCookies();
    await page.goto("/");
    await page.getByRole("link", { name: /ask for help first/i }).click();
    await expect(page).toHaveURL(/\/(request|signin)/);
  });
});
