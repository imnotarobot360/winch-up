# WINCH-UP native staging foundation

This is a **non-production Expo Router skeleton**, not a working SOS client or store-ready build. SOS mutation is intentionally disabled. Do not connect to production project `icpwyepfwkguaocbkawe`.

1. Create an isolated Supabase project with synthetic users, never imported production contacts; disable outgoing SMS, email dispatch and real push.
2. Fill `.env` from `.env.example` using only the staging URL and publishable/anon key. Never provide a service-role key to mobile.
3. Run `cd apps/mobile && npm install --legacy-peer-deps && npx expo install --fix && npm run typecheck` then `npx expo start`.

   `--legacy-peer-deps` is not optional and not cosmetic. This package sits inside the web
   project, so npm walks up and sees the web app's `react-dom` while resolving this app's
   `react`, and refuses with an ERESOLVE naming two versions that have nothing to do with each
   other. They are two independent packages that happen to share a directory tree. Without the
   flag the install fails outright; `npx expo install` hits the same wall and exits non-zero
   after writing the new versions into `package.json`, which looks like a partial success and is
   not one.

   Sign in with Apple needs this install to exist before it can be typechecked or tested at all:
   `apps/mobile/tsconfig.json` extends `expo/tsconfig.base`, so without `node_modules` here even
   the root `npm test` dies while transforming `lib/apple-auth.test.ts`, with an error that names
   tsconfig and never mentions the missing install.
4. Validate native credentials, app identifier, privacy text and permission prompts on physical iOS and Android devices before any store internal testing.

Current placeholders: map visualization, production-compatible auth/waiver, SOS create/state/chat, camera capture, push enrollment and secure staged dispatch. These **are not implemented**. Frontend location is foreground-only and never automatically uploaded.
