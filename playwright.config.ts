import { defineConfig, devices } from "@playwright/test";

/**
 * End-to-end tests.
 *
 * These exist for the things curl and a type checker cannot see. The clearest example in this
 * project's history: `/request` and `/account` return HTTP 200 to curl while a browser correctly
 * lands on `/signin`, because the redirect fires after the head has flushed and arrives as a
 * client navigation rather than a 307. That cost an hour of wrong diagnosis, and a browser is the
 * only instrument that answers it.
 *
 * A dedicated port, so a test run cannot collide with a dev server somebody is already using.
 */
const PORT = 3101;

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",

  use: {
    baseURL: `http://localhost:${PORT}`,
    trace: "on-first-retry",
    // The app is built for someone holding a phone in bright sun. Test it that way by default.
    ...devices["Pixel 5"],
  },

  /**
   * Four shapes, because the spec asks for desktop, tablet, iPhone and Android and because this
   * app is read one-handed in a truck at least as often as it is read at a desk.
   *
   * Pixel 5 and iPhone 13 are not interchangeable here: the iPhone is narrower, and Safari lays
   * out the fixed tab bar and the safe-area inset differently. Tablet is the width where a
   * one-question-per-screen wizard starts to look empty rather than focused.
   */
  projects: [
    { name: "android", use: { ...devices["Pixel 5"] } },
    { name: "iphone", use: { ...devices["iPhone 13"] } },
    { name: "tablet", use: { ...devices["iPad (gen 7)"] } },
    { name: "desktop", use: { ...devices["Desktop Chrome"] } },
  ],

  timeout: 60_000,

  // One, not "as many as there are cores". This machine has 20, and Playwright's default put
  // enough concurrent browsers against a single next start that 18 of 19 tests failed -- every
  // one of which passed when run alone. Pages answer in under half a second here, so the
  // parallelism was buying nothing and costing the entire signal.
  //
  // Two was still too many, for two separate reasons:
  //
  //   The link-crawl tests in navigation.spec and public-pages.spec fetch dozens of URLs each and
  //   intermittently got ECONNRESET from next start. Always green alone. That cost three separate
  //   diagnoses before it was recognised as contention rather than a regression.
  //
  //   membership.spec and recovery-team.spec are both serial state-machine suites and both drive
  //   the same demo accounts. Two workers let them run at the same time, so one suite would cancel
  //   the other's open request out from under it. Each file is serial internally; nothing made
  //   them serial with respect to each other, and Playwright has no way to say so.
  //
  // The whole suite takes about the same wall time either way, because the build dominates.
  workers: 1,

  webServer: {
    // A production build, not `next dev`.
    //
    // Two reasons. It is what a user actually gets -- minified, prerendered, no dev overlay. And
    // `next dev` compiles each route on first request, so running specs in parallel means eight
    // workers each waiting on a cold webpack build: the first run here failed 18 of 19 tests
    // that way, and every one of them passed when run alone.
    command: `npx next build && npx next start -p ${PORT}`,
    url: `http://localhost:${PORT}`,
    reuseExistingServer: !process.env.CI,
    timeout: 240_000,
    stdout: "ignore",
    stderr: "pipe",
  },
});
