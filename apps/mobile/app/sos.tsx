import { SafeAreaView, Text, View } from "react-native";

export default function SosScreen() {
  return <SafeAreaView style={{ padding: 24, gap: 20 }}>
    <Text style={{ color: "#fff", fontSize: 26 }}>Request help</Text>
    <Text style={{ color: "#fbbf24" }}>Not emergency services. For immediate danger, call 911.</Text>
    <View style={{ padding: 16, borderWidth: 1, borderColor: "#fbbf24" }}>
      <Text style={{ color: "#fff" }}>SOS submissions are disabled until a separate test Supabase backend and approved-only responder dispatch are verified end-to-end.</Text>
    </View>
  </SafeAreaView>;
}
