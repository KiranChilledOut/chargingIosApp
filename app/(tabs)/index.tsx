import { ScrollView, StyleSheet, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { BatteryIndicator } from "@/components/BatteryIndicator";
import { PowerTips } from "@/components/PowerTips";
import { useBattery } from "@/hooks/use-battery";
import Colors from "@/constants/colors";

export default function BatteryScreen() {
  const { level, isCharging } = useBattery();
  const insets = useSafeAreaInsets();

  return (
    <ScrollView
      style={[styles.container, { paddingTop: insets.top }]}
      contentContainerStyle={styles.content}
    >
      <View style={styles.main}>
        <BatteryIndicator level={level} isCharging={isCharging} />
        <PowerTips />
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: Colors.light.background,
  },
  content: {
    flexGrow: 1,
  },
  main: {
    flex: 1,
    paddingVertical: 20,
  },
});