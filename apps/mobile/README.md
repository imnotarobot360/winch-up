# WINCH-UP native staging foundation

This is a **non-production Expo Router skeleton**, not a working SOS client or store-ready build. SOS mutation is intentionally disabled. Do not connect to production project `icpwyepfwkguaocbkawe`.

1. Create an isolated Supabase project with synthetic users, never imported production contacts; disable outgoing SMS, email dispatch and real push.
2. Fill `.env` from `.env.example` using the staging Supabase URL, publishable/anon key, and the URL of a staging web app connected to that same Supabase project. The app uses the authenticated `/api/photos/avatar/sign-read` route for a short-lived URL; never provide a service-role key to mobile.
3. Run `cd apps/mobile && npm install && npx expo install --fix && npm run typecheck` then `npx expo start`.
4. Validate native credentials, app identifier, privacy text and permission prompts on physical iOS and Android devices before any store internal testing.

Current placeholders: map visualization, production-compatible auth/waiver, SOS create/state/chat, camera capture, push enrollment and secure staged dispatch. These **are not implemented**. Frontend location is foreground-only and never automatically uploaded.
