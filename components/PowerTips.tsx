import { View, Text, StyleSheet } from "react-native";
import { Battery, Smartphone, Sun, Wifi } from "lucide-react-native";
import Colors from "@/constants/colors";

const tips = [
  {
    icon: Sun,
    text: "Lower screen brightness",
  },
  {
    icon: Wifi,
    text: "Turn off WiFi when not in use",
  },
  {
    icon: Battery,
    text: "Enable low power mode",
  },
  {
    icon: Smartphone,
    text: "Close unused apps",
  },
];

export function PowerTips() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>Power Saving Tips</Text>
      <View style={styles.tips}>
        {tips.map((tip, i) => (
          <View key={i} style={styles.tip}>
            <tip.icon size={24} color={Colors.light.primary} />
            <Text style={styles.tipText}>{tip.text}</Text>
          </View>
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    padding: 20,
  },
  title: {
    fontSize: 20,
    fontWeight: "600",
    marginBottom: 16,
    color: Colors.light.text,
  },
  tips: {
    gap: 16,
  },
  tip: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    padding: 16,
    backgroundColor: Colors.light.cardBackground,
    borderRadius: 12,
  },
  tipText: {
    fontSize: 16,
    color: Colors.light.text,
    opacity: 0.8,
  },
});