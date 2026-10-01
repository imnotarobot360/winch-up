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

  // Clears the rate-limit counters, because several of this app's guards are per-day and the
  // suite is not a person. See e2e/global-setup.ts -- it reads as flake otherwise.
  globalSetup: "./e2e/global-setup.ts",
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

  // A CEILING ON THE WHOLE RUN, so a hang is reported rather than executed.
  //
  // On 2026-09-30 a CI run that had passed in 5 minutes the time before sat for 42 and was
  // killed by the job timeout. A job killed by the runner produces NOTHING -- no report, no
  // annotations, no artifact -- so there was no way to see which test hung. Playwright hitting
  // its own ceiling stops the run and still reports, which is the difference between a
  // diagnosis and another twenty-five minute guess.
  //
  // 25 minutes against a 5-minute suite and a 45-minute job: loose enough that a slow runner
  // is not a failure, tight enough to leave time for the report and the pgTAP step after it.
  globalTimeout: process.env.CI ? 25 * 60_000 : undefined,

  timeout: 60_000,

  /**
   * ASSERTIONS GET FIFTEEN SECONDS, not Playwright's default five.
   *
   * 76 of the 161 assertions in this suite do not ask for a timeout, so they took the 5s default --
   * and 5s is below the noise floor here. One worker drives 250 tests against one `next start`, and a
   * link click in this app is a client-side navigation whose redirect arrives in an RSC payload rather
   * than as a 302, so "did the URL change" is not a question with a fast guaranteed answer under load.
   *
   * The symptom was a different single failure on each full run while every spec passed in isolation:
   * `[iphone] auth-gate` on one, `[android] nearby-alerts` on another, `[android]
   * membership-agreement` on a third -- the last one on `expect(page).toHaveURL(/\/agreement$/)`
   * five seconds after clicking the link that goes there. Whack-a-mole on individual assertions would
   * have fixed three and left seventy-three.
   *
   * This is NOT the same thing as hiding a hang. The per-test timeout above is 60s and unchanged, so
   * anything genuinely stuck still fails the test; 15s only stops a slow-but-correct navigation being
   * reported as a broken one. The 85 assertions that explicitly ask for 20s keep it -- those are the
   * ones waiting on a server action, a dispatch tick or a signed URL, and they chose their number for
   * a reason.
   *
   * If a run ever goes red on a timeout at FIFTEEN seconds, that is worth reading as a real finding
   * rather than raising this again.
   */
  expect: {
    timeout: 15_000,
  },

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
