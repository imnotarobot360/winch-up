import { useState } from "react";
import { Button, SafeAreaView, Text } from "react-native";
import * as Location from "expo-location";

export default function MapScreen() {
  const [label, setLabel] = useState("Location not shared");
  async function locate() {
    const permission = await Location.requestForegroundPermissionsAsync();
    if (!permission.granted) { setLabel("Location permission denied. A manual pin fallback is required before SOS."); return; }
    try {
      const current = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
      setLabel(`Your location is available on this device (accuracy ~${Math.round(current.coords.accuracy ?? 0)} m). It has not been sent.`);
    } catch { setLabel("Could not locate device. Try again or set a manual pin later."); }
  }
  return <SafeAreaView style={{ padding: 24, gap: 20 }}><Text style={{ color: "#fff", fontSize: 24 }}>Map & location</Text><Text style={{ color: "#fff" }}>{label}</Text><Button title="Locate me (foreground only)" onPress={locate} /></SafeAreaView>;
}
