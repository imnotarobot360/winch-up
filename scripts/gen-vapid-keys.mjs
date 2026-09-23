/**
 * Generate one VAPID key pair for web push.
 *
 * Run once. Rotating the pair invalidates every push subscription already registered -- every
 * member silently stops receiving anything and has to opt in again on every device -- so this
 * deliberately prints rather than writing to any file.
 */
import webpush from "web-push";

const { publicKey, privateKey } = webpush.generateVAPIDKeys();

console.log(`
Generated one VAPID pair. Put the first two in Vercel (Production + Preview) and the third
nowhere except Vercel -- it is a secret, and it must not be committed.

  NEXT_PUBLIC_VAPID_PUBLIC_KEY=${publicKey}
  VAPID_PUBLIC_KEY=${publicKey}
  VAPID_PRIVATE_KEY=${privateKey}

Generate this ONCE. Running it again gives a different pair, and every member who has already
turned push on stops receiving notifications without being told why.
`);
