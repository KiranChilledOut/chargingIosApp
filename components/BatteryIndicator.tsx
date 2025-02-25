import { View, StyleSheet, Text } from "react-native";
import { LinearGradient } from "expo-linear-gradient";
import { Zap } from "lucide-react-native";
import Colors from "@/constants/colors";

interface Props {
  level: number;
  isCharging: boolean;
}

export function BatteryIndicator({ level, isCharging }: Props) {
  const percentage = Math.round(level * 100);
  const color = percentage > 20 ? Colors.light.primary : Colors.light.danger;

  return (
    <View style={styles.container}>
      <LinearGradient
        colors={[color, color + "99"]}
        style={[styles.circle, { opacity: percentage / 100 }]}
      >
        <View style={styles.inner}>
          <Text style={styles.percentage}>{percentage}%</Text>
          {isCharging && <Zap size={24} color={Colors.light.warning} />}
        </View>
      </LinearGradient>
      <Text style={styles.status}>
        {isCharging ? "Charging" : percentage <= 20 ? "Low Battery" : "Battery"}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: "center",
    justifyContent: "center",
    padding: 20,
  },
  circle: {
    width: 200,
    height: 200,
    borderRadius: 100,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 20,
  },
  inner: {
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
  },
  percentage: {
    fontSize: 48,
    fontWeight: "bold",
    color: "#fff",
  },
  status: {
    fontSize: 18,
    color: Colors.light.text,
    opacity: 0.8,
  },
});