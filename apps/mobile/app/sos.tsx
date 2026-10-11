import { useEffect, useState } from "react";
import { ActivityIndicator, Pressable, SafeAreaView, ScrollView, Text, View } from "react-native";
import { supabase } from "../lib/supabase";

type Rig = { id: string; make: string | null; model: string | null; year: number | null; is_primary: boolean };

export default function SosScreen() {
  const [rigs, setRigs] = useState<Rig[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    async function load() {
      const { data: { user }, error: authError } = await supabase.auth.getUser();
      if (!active) return;
      if (authError || !user) { setError("Sign in to choose a vehicle from your profile."); setLoading(false); return; }
      const result = await supabase.from("vehicles").select("id, make, model, year, is_primary").eq("user_id", user.id).order("is_primary", { ascending: false });
      if (!active) return;
      if (result.error) setError("Could not load your registered vehicles. Please try again.");
      else setRigs(result.data ?? []);
      setLoading(false);
    }
    void load();
    return () => { active = false; };
  }, []);

  return <SafeAreaView style={{ flex: 1, backgroundColor: "#111b15" }}>
    <ScrollView contentContainerStyle={{ padding: 24, gap: 18 }}>
      <Text style={{ color: "#fff", fontSize: 26, fontWeight: "bold" }}>Request help</Text>
      <Text style={{ color: "#fbbf24" }}>Not emergency services. For immediate danger, call 911.</Text>
      {loading ? <ActivityIndicator accessibilityLabel="Loading vehicles" /> : null}
      {error ? <Text style={{ color: "#fbbf24" }}>{error}</Text> : null}
      {!loading && !error ? <>
        <Text style={{ color: "#fff", fontSize: 19, fontWeight: "bold" }}>Is the vehicle that needs help one from your profile?</Text>
        {rigs.map(rig => <Pressable key={rig.id} accessibilityRole="radio" accessibilityState={{ selected: selected === rig.id }} onPress={() => setSelected(rig.id)} style={{ borderWidth: 2, borderColor: selected === rig.id ? "#ff8c42" : "#526258", borderRadius: 12, padding: 16 }}>
          <Text style={{ color: "#fff" }}>{[rig.year, rig.make, rig.model].filter(Boolean).join(" ") || "Registered vehicle"}{rig.is_primary ? " · Primary" : ""}</Text>
        </Pressable>)}
        <Pressable accessibilityRole="radio" accessibilityState={{ selected: selected === "other" }} onPress={() => setSelected("other")} style={{ borderWidth: 2, borderColor: selected === "other" ? "#ff8c42" : "#526258", borderRadius: 12, padding: 16 }}><Text style={{ color: "#fff" }}>No, another vehicle</Text></Pressable>
        {selected === "other" ? <Text style={{ color: "#fff" }}>You will be able to enter the other vehicle's details when the staging SOS flow is enabled.</Text> : null}
        {selected && selected !== "other" ? <Text style={{ color: "#fff" }}>Vehicle selected. Its details will be prefilled when the staging SOS flow is enabled.</Text> : null}
      </> : null}
      <View style={{ padding: 16, borderWidth: 1, borderColor: "#fbbf24", borderRadius: 12 }}>
        <Text style={{ color: "#fff" }}>SOS sending is disabled until isolated staging dispatch, approved-volunteer routing and privacy checks pass end-to-end. No alerts will be sent.</Text>
      </View>
    </ScrollView>
  </SafeAreaView>;
}
