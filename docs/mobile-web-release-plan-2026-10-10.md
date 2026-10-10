# WINCH-UP mobile + web release preparation plan (NO PUBLIC RELEASE)

Date: 2026-10-10
Baseline: `main` at `bc879ec0b5f39fc0955d0a4d1fb91aed074d09c9`
Status: planning only. This branch MUST NOT be merged or deployed until release gates are met.

## Non-negotiable safety constraints

- No public launch, App Store submission, Play production rollout, production SOS test, real volunteer notification, or production database mutation as part of this preparation.
- Keep existing Next.js web experience, Supabase project and production dispatch state machine intact. Never introduce a second competing dispatch engine in a mobile client.
- Owner decision from 2026-10-08 stands: **only approved volunteers** may be dispatched to. Do not reintroduce Recovery Architecture V2's universal-member dispatch or its conflicting migrations.
- No claims of "production-ready" based on a Vercel READY badge, successful build, or dry-run SMS.
- Require a successful *production* Supabase migration job and independent read-only evidence from `supabase_migrations.schema_migrations` (versions plus relevant schema/function/policy assertions) before release readiness. Earlier run logs should be linked to exact SHA and environment.
- Live SMS is **unverified** until a controlled, consented live send AND receipt/inbound reply are evidenced with provider IDs and timestamps. A `SMS_DRY_RUN=1` test is never live verification.
- Never send trial SOS alerts to real members. Use local/isolated Supabase, test numbers and approved testers. Keep production `SMS_DRY_RUN` unchanged until controlled live-validation approval.
- Requesters must see clear "not emergency services / call 911" guidance. Do not promise rescue, guaranteed arrival, or tracking.
- Protect precise pins, requester phone, recovery token, waiver acceptance, and photo metadata. Preserve existing RLS and column-grant protections.

## Baseline observed in repository

- Next.js 15 / React 19 / TypeScript, Supabase SSR and PostGIS, Mapbox, Twilio, web-push, EN/ES catalogs, Playwright, Vitest, pgTAP.
- PWA manifest exists at `src/app/manifest.ts` with `/request` start_url and 192/512 icons.
- No native iOS/Android application dependencies or native project are present in the inspected root package.json. Search the entire tree before scaffolding to avoid duplication.
- GitHub Actions CI has verify and a local-Supabase browser job; current `browsers` job only runs on pushes to main, not PRs. Add PR-safe browser coverage before trusting mobile changes.
- `docs/deploy.md` calls out legal waiver review and A2P approval as public-launch gates. Re-check current production settings independently.
- Existing app has an approval gate. Recovery V2's incompatible changes were reverted in baseline commit.
- The old README describes local validation; it is NOT proof of a current successful end-to-end physical-device production test.

## Recommended architecture

1. **Web**: keep `src/app` (Next.js) and existing backend. Improve PWA/offline failure states and mobile accessibility without changing dispatch semantics.
2. **Native iOS + Android**: add an Expo / React Native / Expo Router client in `apps/mobile` on a feature branch. Do not ship a simple remote WebView wrapper: App Store minimum-functionality risk, and weak access to platform-specific SOS capabilities.
3. **Shared contracts**: extract pure, side-effect-free Zod schemas, types, enums and EN/ES text where feasible into `packages/contracts`; do not move server-only modules or secrets into mobile bundles.
4. **API boundary**: native client authenticates with Supabase user JWT; all privileged mutations use carefully scoped server endpoints/RPCs enforcing identity, authorization, rate limits and idempotency. No service-role key, Twilio auth token, dispatch secret or Mapbox secret in native app.
5. **Native capabilities**: foreground location + manual pin fallback; camera/photo selection and EXIF-stripping/compression; push token registration and opt-in; deep links for `/r/[token]` and invitation flows; robust offline/error handling. Background location only if justified, explicitly consented and approved.
6. **Notifications**: keep SMS as an independent dispatch channel; add native APNs/FCM via Expo Notifications or another approved provider, with delivery receipts and retry policy. Push must not be treated as proof that a responder was reached.
7. **Distribution**: separate development, staging and production identifiers/configurations. TestFlight and Google Play internal testing only after sandbox verification and owner approval; no public release.

## Execution phases and acceptance criteria

### Phase 0 — freeze and audit (no writes to production)
- Capture main SHA, open PRs, current CI run conclusions, active Vercel deployment SHA, migration run SHA, exact database versions, cron execution and Twilio configuration evidence.
- Inventory routes for SOS creation, accepting/declining, status, cancellation, completion, admin dispatch, and notification delivery.
- Produce dependency graph, secret inventory (names only), threat model, data-flow diagram, and reproducible staging bootstrap.
- **Pass**: audit references exact commits/run IDs and identifies missing evidence as missing.

### Phase 1 — isolate test environment
- Set up dedicated non-production Supabase and Vercel preview with test-only members, disabled real SMS, and no production contact sync.
- Separate app IDs, push credentials, deep-link domains, env vars and signing credentials for dev/staging/prod.
- Enforce CI guard: no `db push --linked`, production Twilio sends, or production deployment from mobile feature branch.
- **Pass**: a test SOS cannot reach any real member and cannot write to production.

### Phase 2 — native foundation
- Scaffold Expo app with typed navigation, English/Spanish, design tokens matching WINCH-UP, accessible bottom tabs, auth session handling and secure token storage.
- Screens: Home/Map, SOS wizard, SOS status, nearby help, volunteer accept/pass, recovery thread/chat, profile/rigs, notifications, membership and legal.
- Handle GPS denied/poor accuracy, network loss, retry without duplicate SOS, image upload failure and account/session expiry.
- **Pass**: development builds on physical iPhone and Android can sign in and complete an isolated request without crashes.

### Phase 3 — SOS correctness and security
- One authoritative server-side state machine; no client-side volunteer matching.
- Verify approved-only dispatch, geographic/equipment matching, first-accept-wins, expiration, ring escalation, cancellation, second helper and stand-down notifications.
- Verify unauthorized users cannot read private phone/pin/photos; precise data only after authorized acceptance.
- **Pass**: pgTAP + unit + E2E pass with explicit negative/security tests and no silent failures.

### Phase 4 — real-device validation
- Two physical devices, two controlled accounts and separate staging backend; run each OS as requester and approved responder.
- Test poor connectivity, app background/terminated state, notification permission denied, push tap/deep link, exact pin, photos, chat, accept race, cancellation and closure.
- Live SMS test requires separate explicit owner authorization, approved A2P/Twilio configuration, `SMS_DRY_RUN` disabled *only* in an approved controlled environment, known recipient numbers, Twilio message SID/status and verified received/inbound response. Never extrapolate from dry-run.
- **Pass**: signed test report with device models/OS, build ID, commit SHA, timestamps, screenshots/logs (redacted) and pass/fail per step.

### Phase 5 — store readiness (prepare, DO NOT submit)
- Apple Developer organization, bundle identifier, signing, privacy nutrition labels, permissions, screenshots, support/privacy URL, account deletion and reviewer demo account; verify current Xcode/SDK requirements.
- Google Play Console account, Android package, signing, Data safety, content rating, permission declarations, internal testing, current target API requirement.
- Texas legal review of terms/waiver/privacy and consent language, emergency disclaimers, member safety and abuse/reporting flow.
- **Pass**: draft store listings, signed builds for internal testing, completed compliance checklist; owner authorizes later submission separately.

## Required test matrix

| Case | Web/PWA | iOS | Android | Evidence |
| --- | --- | --- | --- | --- |
| Signup/login/OTP/session expiry | Yes | Yes | Yes | Auth logs, redacted screen recording |
| Waiver version + emergency acknowledgement | Yes | Yes | Yes | DB assertion + UI |
| SOS create: GPS / pin / offline / duplicate retry | Yes | Yes | Yes | Request ID and events |
| Approved-only responder dispatch | Yes | Yes | Yes | pgTAP and controlled delivery |
| Ring escalation / accept race / stand-down | Yes | Yes | Yes | State transition and message audit |
| Push in foreground/background/closed app | PWA where supported | Yes | Yes | Device receipt |
| SMS send + inbound accept/pass | Backend | Backend | Backend | Live Twilio SID and controlled receipt (separate authorization) |
| Private pin / phone / photos / token authorization | Yes | Yes | Yes | Negative security tests |
| Chat, second helper, cancel and completion | Yes | Yes | Yes | Event trail |
| Accessibility / EN-ES / weak network | Yes | Yes | Yes | Test report |
| Account deletion and data retention | Yes | Yes | Yes | DB assertions |

## Release gate (all must pass)

1. Green CI on exact release SHA, including typecheck, lint, unit, pgTAP, browser E2E, native builds and device smoke tests.
2. Proven production migration success on exact version(s) and independent DB checks; production cron and Edge Function observed healthy.
3. Approved-only dispatch enforced; no reintroduction of Recovery V2 universal dispatch.
4. Controlled full SOS test with actual devices and all relevant notifications; SMS described as live-verified **only** with real delivery/inbound evidence.
5. Legal documents reviewed and published; A2P approval and privacy/data-safety requirements addressed.
6. App Store / Play requirements met; rollback, incident runbook, monitoring and emergency disable switch tested.
7. Owner explicitly approves launch. Until then status is **NOT PRODUCTION READY**.

## Immediate implementation tasks (safe order)

1. Create this planning branch and commit plan; no deploy.
2. Inventory the current routes/RPCs, all production-related workflow steps, and mobile auth/notification constraints.
3. Add isolated staging guardrails and PR E2E coverage.
4. Scaffold Expo mobile client without touching current production runtime.
5. Implement contracts and native SOS flow in staging, then run device tests.
6. Prepare store assets/listings and legal review; no submissions until approved.

## External platform constraints checked 2026-10-10

- Apple App Review Guideline 4.2: a mere repackaged website can be rejected; native app functionality should be meaningful.
- Apple requires Xcode 26+ / iOS 26 SDK for uploads since April 28, 2026 (verify again at submission).
- Google Play new apps/updates require target Android 16 / API 36+ since Aug 31, 2026 (verify again at submission).
- Sources: https://developer.apple.com/app-store/review/guidelines/ ; https://developer.apple.com/news/upcoming-requirements/ ; https://developer.android.com/google/play/requirements/target-sdk
