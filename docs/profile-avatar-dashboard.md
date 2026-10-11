# Dashboard profile photo

The member dashboard now uses the photo already stored in `profiles.avatar_path` in the existing private `member-avatars` bucket. It reuses the existing upload flow and `signAvatar` helper. No schema, bucket, or access-policy changes are included.

## Access and refresh

- The web dashboard gets an initial short-lived URL from the authenticated server page.
- `POST /api/photos/avatar/sign-read` resolves only the current account from the web cookie or verified mobile bearer token. The request cannot choose a profile id or storage path. The profile lookup is constrained by the authenticated `user_id`; the service key stays on the server.
- The endpoint returns a private, no-store response. The signed Storage URL expires after the existing short duration.
- After Account Settings uploads or removes a picture, the web client notifies the current tab and other open tabs. The dashboard requests a fresh signed URL when it mounts, regains focus, receives the avatar update, or sees a new sign-in. Signed-out state clears the image.
- A failed image gets one fresh URL attempt, then initials. A missing profile path, removed object, unavailable storage, or signing failure also falls back to initials.
- Expo iOS/Android uses the same authenticated endpoint and Storage URL. It queries the signed-in user's profile under existing RLS, refreshes on auth changes and when the app becomes active, renders with `resizeMode="cover"`, and links the home avatar to Profile.

## Files changed

- `src/app/api/photos/avatar/sign-read/route.ts` — authenticated short-lived URL endpoint for web and native clients.
- `src/app/[locale]/me/page.tsx` — initial signed URL for the server-rendered dashboard.
- `src/components/ui/avatar.tsx` — shared circular web image, cover crop, and initials fallback.
- `src/components/responder/me-dashboard.tsx` — dashboard avatar, profile navigation, and signed-URL refresh.
- `src/components/account/avatar-upload.tsx` — same-tab and cross-tab update notification.
- `e2e/avatar.spec.ts` — upload persistence, live refresh in an already-open dashboard tab, and fallback after removal.
- `apps/mobile/lib/use-own-profile.ts` — authenticated native profile and avatar refresh.
- `apps/mobile/components/profile-avatar.tsx` — circular native avatar with cover crop and fallback.
- `apps/mobile/app/index.tsx` and `apps/mobile/app/profile.tsx` — dashboard card and profile destination.
- `apps/mobile/.env.example` and `apps/mobile/README.md` — staging web origin configuration and private URL flow.

## Validation

CI results will be recorded in the pull request after its workflows complete. The Playwright avatar suite uses the local CI Supabase Storage service and a test account; it does not connect to production. Physical iPhone and Android device validation requires an isolated staging project and development builds, so it is not claimed by repository CI.

No production deployment, production migration, production data change, or SOS was performed for this feature.
