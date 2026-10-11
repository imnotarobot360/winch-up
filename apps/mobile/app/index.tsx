import { Link } from "expo-router";
import { SafeAreaView, Text, View } from "react-native";

export default function Home() {
  return <SafeAreaView style={{ flex: 1, backgroundColor: "#111b15", padding: 24, justifyContent: "center" }}>
    <Text style={{ color: "#fff", fontSize: 30, fontWeight: "bold" }}>WINCH-UP</Text>
    <Text style={{ color: "#cbd5ce", marginVertical: 16 }}>Different Trails. Same Brotherhood.</Text>
    <View style={{ gap: 20 }}>
      <Link href="/signin" style={{ color: "#ff8c42", fontSize: 20 }}>Sign in</Link>
      <Link href="/map" style={{ color: "#ff8c42", fontSize: 20 }}>Map & location</Link>
      <Link href="/sos" style={{ color: "#ff8c42", fontSize: 20 }}>Request help (staging only)</Link>
    </View>
    <Text style={{ color: "#cbd5ce", marginTop: 32 }}>WINCH-UP is not emergency services. Call 911 for an emergency.</Text>
  </SafeAreaView>;
}
