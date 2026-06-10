import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "com.scoreboard.app",
  appName: "记分器",
  webDir: "mobile-web",
  server: {
    androidScheme: "https"
  }
};

export default config;
