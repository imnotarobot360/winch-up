import { Image, Pressable, Text, View } from "react-native";

const colors = { border: "#526258", text: "#ffffff", panel: "#1b2920" };

export function ProfileAvatar({
  name,
  uri,
  onError,
  onPress,
  size = 80,
}: {
  name: string;
  uri: string | null;
  onError: () => void;
  onPress?: () => void;
  size?: number;
}) {
  const initials = name.trim().split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "?";
  const image = uri ? (
    <Image
      accessibilityLabel="Profile photo"
      source={{ uri }}
      onError={onError}
      resizeMode="cover"
      style={{ width: size, height: size, borderRadius: size / 2, borderWidth: 2, borderColor: colors.border }}
    />
  ) : (
    <View
      accessibilityLabel="Profile initials"
      style={{ width: size, height: size, borderRadius: size / 2, borderWidth: 2, borderColor: colors.border, backgroundColor: colors.panel, alignItems: "center", justifyContent: "center" }}
    >
      <Text style={{ color: colors.text, fontWeight: "800", fontSize: size * 0.3 }}>{initials}</Text>
    </View>
  );

  return onPress ? (
    <Pressable accessibilityRole="button" accessibilityLabel="Open profile" onPress={onPress}>
      {image}
    </Pressable>
  ) : image;
}
