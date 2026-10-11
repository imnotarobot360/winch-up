import { useCallback } from "react";
import { Link, router } from "expo-router";
import { SafeAreaView, Text, View } from "react-native";

import { ProfileAvatar } from "../components/profile-avatar";
import { useOwnProfile } from "../lib/use-own-profile";

const colors = { background: "#111b15", panel: "#1b2920", border: "#526258", text: "#ffffff", muted: "#cbd5ce", orange: "#ff8c42" };

export default function Home() {
  const { signedIn, firstName, recoveriesCount, avatarUrl, retryExpiredAvatar } = useOwnProfile();
  const openProfile = useCallback(() => router.push("/profile"), []);

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: colors.background, padding: 24, justifyContent: "center" }}>
      {signedIn ? (
        <View style={{ flexDirection: "row", alignItems: "center", gap: 16, padding: 16, marginBottom: 24, backgroundColor: colors.panel, borderColor: colors.border, borderWidth: 1, borderRadius: 18 }}>
          <ProfileAvatar name={firstName} uri={avatarUrl} onError={() => void retryExpiredAvatar()} onPress={openProfile} />
          <View style={{ flex: 1, minWidth: 0 }}>
            <Text style={{ color: colors.text, fontSize: 24, fontWeight: "800" }}>HEY {firstName.toUpperCase()}</Text>
            <Text style={{ color: colors.muted, marginTop: 5, fontSize: 15 }}>
              {recoveriesCount} {recoveriesCount === 1 ? "recovery" : "recoveries"}
            </Text>
          </View>
        </View>
      ) : null}

      <Text style={{ color: colors.text, fontSize: 30, fontWeight: "bold" }}>WINCH-UP</Text>
      <Text style={{ color: colors.muted, marginVertical: 16 }}>Different Trails. Same Brotherhood.</Text>
      <View style={{ gap: 20 }}>
        <Link href="/signin" style={{ color: colors.orange, fontSize: 20 }}>Sign in</Link>
        {signedIn ? (
          <Link href="/profile" style={{ color: colors.orange, fontSize: 20 }}>Profile</Link>
        ) : null}
        <Link href="/map" style={{ color: colors.orange, fontSize: 20 }}>Map &amp; location</Link>
        <Link href="/sos" style={{ color: colors.orange, fontSize: 20 }}>Request help (staging only)</Link>
      </View>
      <Text style={{ color: colors.muted, marginTop: 32 }}>WINCH-UP is not emergency services. Call 911 for an emergency.</Text>
    </SafeAreaView>
  );
}
