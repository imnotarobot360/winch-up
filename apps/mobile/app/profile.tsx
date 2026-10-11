import { Link } from "expo-router";
import { SafeAreaView, Text, View } from "react-native";

import { ProfileAvatar } from "../components/profile-avatar";
import { useOwnProfile } from "../lib/use-own-profile";

const colors = { background: "#111b15", panel: "#1b2920", border: "#526258", text: "#ffffff", muted: "#cbd5ce", orange: "#ff8c42" };

export default function Profile() {
  const { signedIn, firstName, recoveriesCount, avatarUrl, retryExpiredAvatar } = useOwnProfile();

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: colors.background, padding: 24 }}>
      <Text style={{ color: colors.text, fontSize: 28, fontWeight: "800", marginBottom: 20 }}>Profile</Text>
      <View style={{ flexDirection: "row", alignItems: "center", gap: 16, padding: 16, backgroundColor: colors.panel, borderColor: colors.border, borderWidth: 1, borderRadius: 18 }}>
        <ProfileAvatar name={firstName} uri={avatarUrl} onError={() => void retryExpiredAvatar()} />
        <View style={{ flex: 1 }}>
          <Text style={{ color: colors.text, fontSize: 22, fontWeight: "800" }}>HEY {firstName.toUpperCase()}</Text>
          <Text style={{ color: colors.muted, marginTop: 5 }}>
            {recoveriesCount} {recoveriesCount === 1 ? "recovery" : "recoveries"}
          </Text>
        </View>
      </View>
      {!signedIn ? <Text style={{ color: colors.muted, marginTop: 16 }}>Sign in to see your profile photo.</Text> : null}
      <Link href="/" style={{ color: colors.orange, fontSize: 18, marginTop: 24 }}>Back to dashboard</Link>
    </SafeAreaView>
  );
}
