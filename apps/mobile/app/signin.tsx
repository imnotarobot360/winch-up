import { useEffect, useState } from "react";
import { router } from "expo-router";
import { Button, SafeAreaView, Text, TextInput } from "react-native";
import * as AppleAuthentication from "expo-apple-authentication";
import * as Crypto from "expo-crypto";
import { supabase } from "../lib/supabase";
import { signInWithApple } from "../lib/apple-auth";

/**
 * A random string for the nonce.
 *
 * Only the RAW value is ever sent to Supabase; Apple receives its SHA-256. `apple-auth.ts` holds
 * that contract and a test asserts which form goes where, because swapping them fails on a device
 * with a message that never mentions nonces.
 */
function randomNonce(): string {
  return Array.from(Crypto.getRandomValues(new Uint8Array(16)))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export default function SignIn() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");
  const [appleReady, setAppleReady] = useState(false);

  // Android has no Sign in with Apple sheet, and neither does iOS below 13. The button is not
  // rendered at all rather than rendered and refusing: a control that cannot work is worse than
  // absent, which is the same position the web takes by reading /auth/v1/settings.
  useEffect(() => {
    let alive = true;
    AppleAuthentication.isAvailableAsync()
      .then((ok) => alive && setAppleReady(ok))
      .catch(() => alive && setAppleReady(false));
    return () => {
      alive = false;
    };
  }, []);

  async function signIn() {
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (error) setMessage(error.message);
    else router.replace("/");
  }

  async function continueWithApple() {
    setMessage("");

    const result = await signInWithApple({
      isAvailable: () => AppleAuthentication.isAvailableAsync(),
      signInAsync: ({ nonce }) =>
        AppleAuthentication.signInAsync({
          requestedScopes: [
            AppleAuthentication.AppleAuthenticationScope.FULL_NAME,
            AppleAuthentication.AppleAuthenticationScope.EMAIL,
          ],
          nonce,
        }),
      signInWithIdToken: async ({ token, nonce }) => {
        const { error } = await supabase.auth.signInWithIdToken({
          provider: "apple",
          token,
          nonce,
        });
        return { error };
      },
      randomNonce,
      sha256: (value) =>
        Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, value),
    });

    // Dismissing the sheet is a choice, not a fault, so it says nothing at all.
    if (result.status === "cancelled") return;
    if (result.status === "unavailable") return;
    if (result.status === "failed") {
      setMessage(`Apple sign-in failed (${result.reason}).`);
      return;
    }

    // APPLE SENDS THE NAME ONCE, on the first authorization for this Apple ID, and never again.
    // It is written here or it is lost. Only into an EMPTY display name: a member who has since
    // set their own name must not have it overwritten by one Apple remembered from years ago.
    if (result.displayName) {
      const { data } = await supabase.auth.getUser();
      const id = data.user?.id;
      if (id) {
        const { data: profile } = await supabase
          .from("profiles")
          .select("display_name")
          .eq("user_id", id)
          .maybeSingle();
        if (profile && !profile.display_name) {
          // `.select()` so a zero-row update is visible rather than reported as success — the
          // mistake /account made on the web for weeks.
          await supabase
            .from("profiles")
            .update({ display_name: result.displayName })
            .eq("user_id", id)
            .select("user_id");
        }
      }
    }

    router.replace("/");
  }

  return (
    <SafeAreaView style={{ padding: 24, gap: 16 }}>
      <Text style={{ color: "#fff", fontSize: 24 }}>Staging sign in</Text>
      <TextInput
        accessibilityLabel="Email"
        autoCapitalize="none"
        keyboardType="email-address"
        value={email}
        onChangeText={setEmail}
        placeholder="Email"
        style={{ backgroundColor: "#fff", padding: 12 }}
      />
      <TextInput
        accessibilityLabel="Password"
        secureTextEntry
        value={password}
        onChangeText={setPassword}
        placeholder="Password"
        style={{ backgroundColor: "#fff", padding: 12 }}
      />
      <Button title="Sign in" onPress={signIn} />

      {/* Apple's own component. Their brand guidelines do not permit a hand-drawn substitute, and
          App Review checks it. */}
      {appleReady ? (
        <AppleAuthentication.AppleAuthenticationButton
          buttonType={AppleAuthentication.AppleAuthenticationButtonType.CONTINUE}
          buttonStyle={AppleAuthentication.AppleAuthenticationButtonStyle.WHITE}
          cornerRadius={8}
          style={{ height: 48 }}
          onPress={continueWithApple}
        />
      ) : null}

      <Text style={{ color: "#fff" }}>{message}</Text>
    </SafeAreaView>
  );
}
