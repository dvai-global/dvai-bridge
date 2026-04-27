// Autolinking configuration for @dvai-bridge/react-native.
// Consumed by `npx react-native config` during `pod install` (iOS) and Gradle
// sync (Android). The TurboModule's iOS pod and Android Gradle module are
// declared here so consumers don't need to add anything manually beyond
// `npm install @dvai-bridge/react-native`.
const path = require("node:path");

module.exports = {
  dependency: {
    platforms: {
      ios: {
        // The podspec lives at the package root for compatibility with the
        // standard RN library template (CocoaPods looks here by default).
        podspecPath: path.join(__dirname, "DVAIBridgeNative.podspec"),
      },
      android: {
        sourceDir: path.join(__dirname, "android"),
        packageImportPath: "import co.deepvoiceai.bridge.rn.DVAIBridgePackage;",
        packageInstance: "new DVAIBridgePackage()",
      },
    },
  },
};
