import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "co.deepvoiceai.bridge.example.capacitor",
  appName: "DVAI Bridge Capacitor Example",
  webDir: "www",
  server: {
    androidScheme: "https",
  },
  // The plugin's own Android manifest already whitelists cleartext to
  // 127.0.0.1 / localhost, so the host app does not need to override
  // network_security_config.xml.
};

export default config;
