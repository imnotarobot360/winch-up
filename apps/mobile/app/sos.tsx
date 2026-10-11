import { useEffect, useState } from "react";
import { ActivityIndicator, Pressable, SafeAreaView, ScrollView, Text, TextInput, View } from "react-native";
import { supabase } from "../lib/supabase";

type Rig = { id: string; make: string | null; model: string | null; year: number | null; is_primary: boolean };
type VehicleChoice = "profile" | "other" | null;

const colors = { background: "#111b15", panel: "#1b2920", border: "#526258", text: "#ffffff", muted: "#cbd5ce", orange: "#ff8c42", warning: "#fbbf24" };

export default function SosScreen() {
  const [rigs, setRigs] = useState<Rig[]>([]);
  const [choice, setChoice] = useState<VehicleChoice>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [make, setMake] = useState("");
  const [model, setModel] = useState("");
  const [year, setYear] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    async function load() {
      const { data: { user }, error: authError } = await supabase.auth.getUser();
      if (!active) return;
      if (authError || !user) {
        setError("Sign in to choose a vehicle from your profile.");
        setLoading(false);
        return;
      }
      const result = await supabase.from("vehicles")
        .select("id, make, model, year, is_primary")
        .eq("user_id", user.id)
        .order("is_primary", { ascending: false });
      if (!active) return;
      if (result.error) setError("Could not load your registered vehicles. Please try again.");
      else setRigs(result.data ?? []);
      setLoading(false);
    }
    void load();
    return () => { active = false; };
  }, []);

  function chooseProfileVehicle(rig: Rig) {
    setSelected(rig.id);
    setMake(rig.make ?? "");
    setModel(rig.model ?? "");
    setYear(rig.year?.toString() ?? "");
  }

  function selectChoice(next: Exclude<VehicleChoice, null>) {
    setChoice(next);
    setSelected(null);
    if (next === "other") {
      setMake("");
      setModel("");
      setYear("");
    }
  }

  const radioStyle = (active: boolean) => ({
    borderWidth: 2,
    borderColor: active ? colors.orange : colors.border,
    borderRadius: 12,
    padding: 16,
    backgroundColor: active ? "#26372b" : colors.panel,
  });

  return <SafeAreaView style={{ flex: 1, backgroundColor: colors.background }}>
    <ScrollView contentContainerStyle={{ padding: 24, gap: 18 }}>
      <Text style={{ color: colors.text, fontSize: 28, fontWeight: "800" }}>Request help</Text>
      <Text style={{ color: colors.warning, fontSize: 16 }}>WINCH-UP is not emergency services. For immediate danger, call 911.</Text>

      {loading ? <ActivityIndicator accessibilityLabel="Loading profile vehicles" color={colors.orange} /> : null}
      {error ? <Text accessibilityRole="alert" style={{ color: colors.warning }}>{error}</Text> : null}

      {!loading && !error ? <>
        <View style={{ gap: 12 }}>
          <Text style={{ color: colors.text, fontSize: 19, fontWeight: "700" }}>
            Is the vehicle that needs help one from your profile?
          </Text>
          <Pressable
            accessibilityRole="radio"
            accessibilityState={{ selected: choice === "profile" }}
            onPress={() => selectChoice("profile")}
            style={radioStyle(choice === "profile")}
          >
            <Text style={{ color: colors.text, fontSize: 16, fontWeight: "700" }}>Yes, it is in my profile</Text>
          </Pressable>
          <Pressable
            accessibilityRole="radio"
            accessibilityState={{ selected: choice === "other" }}
            onPress={() => selectChoice("other")}
            style={radioStyle(choice === "other")}
          >
            <Text style={{ color: colors.text, fontSize: 16, fontWeight: "700" }}>No, it is another vehicle</Text>
          </Pressable>
        </View>

        {choice === "profile" ? <View style={{ gap: 12 }}>
          <Text style={{ color: colors.muted, fontSize: 15 }}>
            {rigs.length ? "Choose the vehicle that needs help." : "You do not have a vehicle saved in your profile yet. Select “No” to enter another vehicle."}
          </Text>
          {rigs.map(rig => {
            const label = [rig.year, rig.make, rig.model].filter(Boolean).join(" ") || "Registered vehicle";
            return <Pressable
              key={rig.id}
              accessibilityRole="radio"
              accessibilityLabel={label + (rig.is_primary ? ", primary vehicle" : "")}
              accessibilityState={{ selected: selected === rig.id }}
              onPress={() => chooseProfileVehicle(rig)}
              style={radioStyle(selected === rig.id)}
            >
              <Text style={{ color: colors.text, fontSize: 16, fontWeight: "700" }}>
                {label}{rig.is_primary ? " · Primary" : ""}
              </Text>
              {selected === rig.id ? <Text style={{ color: colors.orange, marginTop: 6 }}>Selected from your profile</Text> : null}
            </Pressable>;
          })}
        </View> : null}

        {choice === "other" ? <View style={{ gap: 12 }}>
          <Text style={{ color: colors.muted }}>Enter the vehicle details so helpers know what to look for.</Text>
          <TextInput accessibilityLabel="Vehicle make" value={make} onChangeText={setMake} placeholder="Make (for example, Jeep)" placeholderTextColor="#69786d" maxLength={40} style={{ backgroundColor: colors.panel, borderColor: colors.border, borderWidth: 1, borderRadius: 10, color: colors.text, padding: 14 }} />
          <TextInput accessibilityLabel="Vehicle model" value={model} onChangeText={setModel} placeholder="Model (for example, Wrangler)" placeholderTextColor="#69786d" maxLength={40} style={{ backgroundColor: colors.panel, borderColor: colors.border, borderWidth: 1, borderRadius: 10, color: colors.text, padding: 14 }} />
          <TextInput accessibilityLabel="Vehicle year" value={year} onChangeText={(value) => setYear(value.replace(/[^0-9]/g, "").slice(0, 4))} placeholder="Year (optional)" placeholderTextColor="#69786d" keyboardType="number-pad" maxLength={4} style={{ backgroundColor: colors.panel, borderColor: colors.border, borderWidth: 1, borderRadius: 10, color: colors.text, padding: 14 }} />
        </View> : null}
      </> : null}

      <View style={{ padding: 16, borderWidth: 1, borderColor: colors.warning, borderRadius: 12, backgroundColor: "#292719", gap: 6 }}>
        <Text style={{ color: colors.text, fontWeight: "700" }}>SOS sending is disabled</Text>
        <Text style={{ color: colors.muted }}>
          No request or alert will be sent. Dispatch stays disabled until isolated staging, approved-volunteer routing and privacy checks pass end-to-end.
        </Text>
      </View>
    </ScrollView>
  </SafeAreaView>;
}
