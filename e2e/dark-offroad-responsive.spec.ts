import { expect, test, type Page, type TestInfo } from "@playwright/test";

async function signIn(page: Page) {
  await page.goto("/signin");
  // Wait for React before editing controlled inputs, particularly on WebKit.
  await page.locator("form").first().evaluate((element) => new Promise<void>((resolve) => {
    const timer = setInterval(() => {
      if (Object.keys(element).some((key) => key.startsWith("__react"))) {
        clearInterval(timer);
        resolve();
      }
    }, 25);
  }));
  await page.getByLabel(/email|correo/i).pressSequentially("mike@winchup.test");
  await page.getByLabel(/password|contraseña/i).pressSequentially("recovery-demo-2026");
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/signin"));
}

async function fitsScreen(page: Page) {
  const dimensions = await page.evaluate(() => ({
    viewport: document.documentElement.clientWidth,
    document: document.documentElement.scrollWidth,
    scheme: getComputedStyle(document.documentElement).colorScheme,
  }));
  expect(dimensions.document, "No horizontal scrolling at this viewport").toBeLessThanOrEqual(dimensions.viewport + 1);
  expect(dimensions.scheme).toBe("dark");
}

async function capture(page: Page, testInfo: TestInfo, name: string) {
  const viewport = testInfo.project.use.viewport;
  if (viewport) await page.setViewportSize(viewport);
  await page.evaluate(() => {
    if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
    window.scrollTo(0, 0);
  });
  await page.screenshot({ path: testInfo.outputPath(`${name}.png`), fullPage: true });
}

test.describe("dark off-road presentation", () => {
  test("public navigation fits narrow phones, landscape and desktop in both languages", async ({ page }) => {
    for (const locale of ["", "/es"]) {
      await page.goto(`${locale}/board`);
      await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
      for (const viewport of [
        { width: 320, height: 568 },
        { width: 390, height: 664 },
        { width: 412, height: 823 },
        { width: 844, height: 390 },
        { width: 1440, height: 900 },
      ]) {
        await page.setViewportSize(viewport);
        await fitsScreen(page);
        const nav = page.getByRole("navigation", { name: /main|principal/i });
        await expect(nav).toBeVisible();
        const current = nav.locator('[aria-current="page"]');
        await expect(current).toHaveAttribute("href", /\/board$/);
        for (const link of await nav.getByRole("link").all()) {
          const box = await link.boundingBox();
          expect(box?.height, "Navigation target height").toBeGreaterThanOrEqual(44);
          expect(box?.width, "Navigation target width").toBeGreaterThanOrEqual(44);
        }
        const labels = await nav.locator("a > span:last-child").evaluateAll((elements) =>
          elements.map((element) => element.getBoundingClientRect().height),
        );
        expect(labels.every((height) => height <= 20), "Tab labels stay on one line").toBe(true);
      }
    }
  });

  test("home, profile, settings and inbox remain usable on this device", async ({ page }, testInfo) => {
    await signIn(page);
    for (const [path, name] of [["/", "home"], ["/me", "profile"], ["/account", "settings"], ["/messages", "inbox"]]) {
      await page.goto(path);
      await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
      await fitsScreen(page);
      await capture(page, testInfo, name);
      if (path === "/account") {
        await expect(page.locator('.winch-bottom-nav [aria-current="page"]')).toHaveAttribute("href", /\/me$/);
      }
      if (path === "/") {
        const primary = page.locator("main").getByRole("link", { name: /^send sos$/i });
        await expect(primary).toBeVisible();
        await primary.scrollIntoViewIfNeeded();
        const actionBox = await primary.boundingBox();
        const navBox = await page.getByRole("navigation", { name: /main/i }).boundingBox();
        expect(actionBox!.y + actionBox!.height, "SOS action stays above navigation").toBeLessThanOrEqual(navBox!.y);
      }
    }
  });

  test("SOS retains the emergency gate and location requirement with accessible controls", async ({ page }, testInfo) => {
    await signIn(page);
    await page.goto("/request");
    const next = page.getByRole("button", { name: /^next$/i });
    await expect(next).toBeDisabled();
    await expect(page.getByRole("link", { name: /call 911/i })).toHaveAttribute("href", "tel:911");
    await expect(page.locator(".winch-bottom-nav")).toHaveCount(0);
    await page.getByRole("checkbox", { name: /nobody is hurt or in danger/i }).check();
    await expect(next).toBeEnabled();
    await fitsScreen(page);
    await capture(page, testInfo, "sos-emergency");
    await next.click();
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(/where are you/i);
    await expect(page.getByRole("heading", { level: 1 })).toBeFocused();
    await expect(next).toBeDisabled();
    await page.getByRole("button", { name: /paste/i }).click();
    await page.getByLabel(/paste a location/i).pressSequentially("29.7604, -95.3698");
    await page.getByRole("button", { name: /find it/i }).click();
    await expect(page.getByText(/got your location/i)).toBeVisible();
    await expect(next).toBeEnabled();
    await next.click();
    await next.click(); // Photos are optional; no Storage request is made.
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(/what are you driving/i);
    for (const width of [320, 390, 412]) {
      await page.setViewportSize({ width, height: 700 });
      await fitsScreen(page);
      const truck = page.getByRole("radio", { name: /^truck$/i });
      const box = await truck.boundingBox();
      expect(box!.height).toBeGreaterThanOrEqual(56);
    }
    await capture(page, testInfo, "sos-vehicle");
  });

  test("a real private conversation wraps long text and leaves room for its composer", async ({ page }, testInfo) => {
    await signIn(page);
    // Use a different pair from direct-messages.spec.ts, so neither suite owns the other's thread.
    await page.goto("/members/00000000-0000-4000-8000-000000000004");
    const entry = page.getByRole("button", { name: /^message |open (?:the )?conversation/i });
    await expect(entry).toBeVisible();
    const existing = /open (?:the )?conversation/i.test(await entry.innerText());
    await entry.click();
    const note = `mobile-${Math.random().toString(36).slice(2)}-${"x".repeat(240)}`;
    if (existing) {
      await page.waitForURL(/\/messages\/[0-9a-f-]{36}$/);
    }
    await page.getByRole("textbox").last().fill(note);
    await page.getByRole("button", { name: /^send$/i }).click();
    await page.waitForURL(/\/messages\/[0-9a-f-]{36}$/);
    await expect(page.getByText(note, { exact: true })).toBeVisible();
    await expect(page.locator(".winch-bottom-nav")).toHaveCount(0);
    for (const viewport of [
      { width: 320, height: 568 },
      { width: 390, height: 450 }, // Reduced viewport as when a software keyboard is open.
      { width: 844, height: 390 },
    ]) {
      await page.setViewportSize(viewport);
      await fitsScreen(page);
      const composer = page.getByRole("textbox").last();
      await composer.focus();
      await composer.scrollIntoViewIfNeeded();
      const send = page.getByRole("button", { name: /^send$/i });
      await expect(send).toBeDisabled();
      const box = await send.boundingBox();
      expect(box!.y + box!.height, "Send is reachable in the reduced viewport").toBeLessThanOrEqual(viewport.height);
    }
    await capture(page, testInfo, "private-chat");
  });

  test("shared recovery tracking shows its timeline without exposing participant chat", async ({ page }, testInfo) => {
    // A documented local seed, read-only. No live recovery is filed by this suite.
    await page.goto("/r/demo-accepted-token-cccccc");
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await expect(page.locator(".winch-timeline li").first()).toBeVisible();
    await expect(page.locator(".winch-bottom-nav")).toHaveCount(0);
    await expect(page.getByRole("textbox", { name: /message/i })).toHaveCount(0);
    for (const width of [320, 390, 412, 844]) {
      await page.setViewportSize({ width, height: 700 });
      await fitsScreen(page);
    }
    await capture(page, testInfo, "recovery-tracking");
  });
});
