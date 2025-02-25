import { create } from "zustand";
import * as Battery from "expo-battery";
import { useEffect } from "react";
import { Platform } from "react-native";

interface BatteryState {
  level: number;
  isCharging: boolean;
  lowPowerMode: boolean;
  initialize: () => Promise<void>;
}

export const useBatteryStore = create<BatteryState>((set) => ({
  level: 1,
  isCharging: false,
  lowPowerMode: false,
  initialize: async () => {
    if (Platform.OS === "web") {
      set({ level: 1, isCharging: false, lowPowerMode: false });
      return;
    }

    const [level, state] = await Promise.all([
      Battery.getBatteryLevelAsync(),
      Battery.getBatteryStateAsync(),
    ]);

    set({
      level,
      isCharging: state === Battery.BatteryState.CHARGING,
      lowPowerMode: false,
    });
  },
}));

export function useBattery() {
  const { initialize } = useBatteryStore();

  useEffect(() => {
    if (Platform.OS === "web") return;

    initialize();

    const subscription = Battery.addBatteryLevelListener(({ batteryLevel }) => {
      useBatteryStore.setState({ level: batteryLevel });
    });

    const stateSubscription = Battery.addBatteryStateListener(({ batteryState }) => {
      useBatteryStore.setState({
        isCharging: batteryState === Battery.BatteryState.CHARGING,
      });
    });

    return () => {
      subscription.remove();
      stateSubscription.remove();
    };
  }, []);

  return useBatteryStore();
}