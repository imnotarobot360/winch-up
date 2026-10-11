import { Stack } from "expo-router";

export default function RootLayout() {
  return <Stack screenOptions={{ headerStyle: { backgroundColor: "#111b15" }, headerTintColor: "#fff", contentStyle: { backgroundColor: "#111b15" } }} />;
}
