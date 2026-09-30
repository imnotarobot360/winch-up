import { expect, test, type Page } from "@playwright/test";

/**
 * The membership agreement, end to end, through the UI only.
 *
 * WHY THIS EXISTS RATHER THAN MORE pgTAP
 *
 * The database suite for this feature is thorough and it proves the wrong half. Every one of its
 * 39 assertions calls sign_membership_agreement() directly, and the one bug that actually
 * shipped was invisible to all of them: admin_membership_signatures was declared STABLE while
 * writing an audit row, so PostgREST ran it in a read-only transaction and it failed with 25006
 * over HTTP while passing in psql. The admin screen said "1 signed" directly above "Nobody has
 * signed this version."
 *
 * A suite that never makes an HTTP request cannot see that. This one publishes, signs and reads
 * the record back by clicking, which is the only way that class of bug shows up.
 *
 * IT LEAVES A PUBLISHED AGREEMENT BEHIND, ON PURPOSE
 *
 * There is no unpublish, deliberately -- requirement 13 keeps every historical version, and a
 * test that could delete one would be testing something the product does not do. So a local run
 * leaves version N in force and unsigned members see the prompt on the home map afterwards.
 *
 * That is safe: `membership.required` stays false, so nothing is gated, and the signed-out home
 * assertions in public-pages.spec are on the landing page, which never shows it. On CI the
 * database is fresh every run.
 *
 * Re-running locally publishes a further version. That is the correct behaviour and the test is
 * written for it -- it asserts on "the current version", never on "version 1".
 */

const ADMIN = { email: "admin@winchup.test", password: "recovery-demo-2026" };
const MEMBER = { email: "rosa@winchup.test", password: "recovery-demo-2026" };

const MEMBER_LEGAL_NAME = "Rosa Maria Delgado";

// Long enough to clear the 20-character floor admin_publish_membership_agreement enforces on
// both languages, and obviously not legal text, so a stray local run cannot be mistaken for one.
const BODY_EN =
  "END-TO-END TEST AGREEMENT. Not legal text. Clause one: this document exists to prove the " +
  "signing flow works. Clause two: the assumption of risk summary is rendered separately, " +
  "above this text, and is not buried in here.";
const BODY_ES =
  "ACUERDO DE PRUEBA DE EXTREMO A EXTREMO. No es texto legal. Clausula uno: este documento " +
  "existe para comprobar que el flujo de firma funciona. Clausula dos: el resumen de riesgos " +
  "se muestra por separado, arriba de este texto.";

async function signIn(page: Page, who: { email: string; password: string }) {
  await page.goto("/signin");

  // WAIT FOR HYDRATION BEFORE TYPING A SINGLE CHARACTER.
  //
  // Without this the suite failed on all three projects with a DISABLED sign-in button and
  // both fields EMPTY in the snapshot -- which reads like a broken sign-in form and is nothing
  // of the kind. Keystrokes delivered before React attaches land in the pre-hydration DOM;
  // hydration then takes the inputs over and resets them to their initial value, so the typing
  // is silently undone and the form never becomes valid. It is a race, so it passed for weeks
  // and then failed three times in a row.
  //
  // React writes __reactFiber$... / __reactProps$... onto the nodes it has attached to, so the
  // presence of one is the signal. Retrying the typing would have been the other fix and is
  // worse: clearing a field to retype it is exactly the fill() behaviour these suites avoid,
  // because on WebKit it wipes the sibling field.
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

  // pressSequentially, not fill. On WebKit, fill() on one field clears its sibling -- the same
  // finding the membership and auth-gate suites are written around.
  await page.getByLabel(/email|correo/i).pressSequentially(who.email);
  await page.getByLabel(/password|contraseña/i).pressSequentially(who.password);
  await page.getByRole("button", { name: /^sign in$|^entrar$/i }).click();
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

test.describe("the membership agreement", () => {
  test("an admin publishes it, a member signs it, and the admin can read the record", async ({
    page,
  }) => {
    // ---------------------------------------------------------------- publish
    await signIn(page, ADMIN);
    await page.goto("/admin/membership");

    // The screen fetches through useAdminData and renders an ellipsis until it lands, so wait
    // for something that only exists after the load rather than racing it.
    await expect(page.getByRole("heading", { name: /publish a new version/i }))
      .toBeVisible({ timeout: 20_000 });

    // Whether the gate is in force has to be stated. Publishing an agreement and assuming it is
    // enforced is the obvious mistake, so the screen says which way it is set either way.
    await expect(page.getByText(/signing is (not )?required/i)).toBeVisible();

    await page.getByLabel(/english text/i).fill(BODY_EN);
    await page.getByLabel(/spanish text/i).fill(BODY_ES);
    await page.getByRole("button", { name: /^publish$/i }).click();

    await expect(page.getByText(/version \d+ published/i)).toBeVisible({ timeout: 20_000 });

    // The published version now carries a hash. Asserted as a shape, not a value: the whole
    // point is that it is derived from the text, so hardcoding one would be asserting the text.
    await expect(page.getByText(/^[0-9a-f]{64}$/).first()).toBeVisible();

    await signOut(page);

    // ----------------------------------------------------------------- prompt
    await signIn(page, MEMBER);
    await page.goto("/");

    // Requirement 10: an existing member meets this on the screen they land on.
    const prompt = page.getByText(/sign the membership agreement to request/i);
    await expect(prompt).toBeVisible({ timeout: 20_000 });

    await page.getByRole("link", { name: /read and sign/i }).click();
    await expect(page).toHaveURL(/\/agreement$/);

    // ------------------------------------------------------------------- read
    // Requirement 5: the risk summary is its own thing, above the document, not clause fourteen.
    await expect(page.getByRole("heading", { name: /read this part carefully/i })).toBeVisible();
    await expect(page.getByText(/winches, straps and chains fail under load/i)).toBeVisible();

    // Requirement 3: the full text is on the page.
    await expect(page.getByText(/END-TO-END TEST AGREEMENT/)).toBeVisible();

    // Requirement 15: the consent separation is stated where somebody signing will see it.
    await expect(page.getByText(/separate from how we contact you/i)).toBeVisible();

    // Requirement 4: nothing is pre-ticked. Checked before anything is clicked, because a
    // pre-ticked consent box is the single thing this requirement exists to prevent.
    const riskBox = page.getByRole("checkbox").first();
    const agreeBox = page.getByRole("checkbox").nth(1);
    await expect(riskBox).not.toBeChecked();
    await expect(agreeBox).not.toBeChecked();

    // ------------------------------------------------------------- refusals
    await page.getByRole("button", { name: /^sign the agreement$/i }).click();
    // Not getByRole("alert"): Next renders a route announcer with that role on every page, so
    // the role alone is ambiguous and strict mode refuses it. The text is the assertion anyway.
    await expect(page.getByText(/tick both boxes/i)).toBeVisible();

    await riskBox.check();
    await agreeBox.check();

    // Requirement 4: the typed signature has to be the legal name, and initials are not one.
    await page.getByLabel(/^your full legal name$/i).fill(MEMBER_LEGAL_NAME);
    await page.getByLabel(/type your full legal name to sign/i).fill("RMD");
    await page.getByRole("button", { name: /^sign the agreement$/i }).click();
    await expect(page.getByText(/match your full legal name/i)).toBeVisible();

    // -------------------------------------------------------------------- sign
    await page.getByLabel(/type your full legal name to sign/i).fill(MEMBER_LEGAL_NAME);
    await page.getByRole("button", { name: /^sign the agreement$/i }).click();

    await expect(page.getByRole("heading", { name: /you have signed this agreement/i }))
      .toBeVisible({ timeout: 20_000 });
    await expect(page.getByText(new RegExp(MEMBER_LEGAL_NAME))).toBeVisible();
    // Here the hash is labelled, unlike the admin list where it is bare -- so the member is
    // shown a reference they could quote, not a stray 64 characters of hex.
    await expect(page.getByText(/document reference [0-9a-f]{64}/i)).toBeVisible();

    // It survives a reload, which is the difference between a signature and a screen state.
    await page.reload();
    await expect(page.getByRole("heading", { name: /you have signed this agreement/i }))
      .toBeVisible();

    // And the prompt is gone from home.
    await page.goto("/");
    await expect(page.getByText(/sign the membership agreement to request/i)).toHaveCount(0);

    await signOut(page);

    // ------------------------------------------------------------- the record
    // The half that only an HTTP request can prove. This is where the stable-function bug lived.
    await signIn(page, ADMIN);
    await page.goto("/admin/membership");

    await page.getByRole("button", { name: /^signatures$/i }).first().click();

    await expect(page.getByText(/recorded in the audit log/i)).toBeVisible();
    await expect(page.getByText(MEMBER_LEGAL_NAME)).toBeVisible({ timeout: 20_000 });
    await expect(page.getByText(/nobody has signed this version/i)).toHaveCount(0);

    await signOut(page);
  });
});
