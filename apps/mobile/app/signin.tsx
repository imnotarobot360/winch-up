import { useState } from "react";
import { router } from "expo-router";
import { Button, SafeAreaView, Text, TextInput } from "react-native";
import { supabase } from "../lib/supabase";

export default function SignIn() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState("");
  async function signIn() {
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (error) setMessage(error.message);
    else router.replace("/");
  }
  return <SafeAreaView style={{ padding: 24, gap: 16 }}>
    <Text style={{ color: "#fff", fontSize: 24 }}>Staging sign in</Text>
    <TextInput accessibilityLabel="Email" autoCapitalize="none" keyboardType="email-address" value={email} onChangeText={setEmail} placeholder="Email" style={{ backgroundColor: "#fff", padding: 12 }} />
    <TextInput accessibilityLabel="Password" secureTextEntry value={password} onChangeText={setPassword} placeholder="Password" style={{ backgroundColor: "#fff", padding: 12 }} />
    <Button title="Sign in" onPress={signIn} />
    <Text style={{ color: "#fff" }}>{message}</Text>
  </SafeAreaView>;
}
