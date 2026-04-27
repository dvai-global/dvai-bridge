# Example consumer

The DVAI-Bridge project ships **scripted samples**, not standalone apps —
in keeping with the project-wide convention used across the iOS, Android,
and Capacitor SDKs.

For a copy-paste-ready React Native quickstart:

- See the [React Native SDK guide](../../../docs/guide/react-native-sdk.md).
- The Quickstart section there walks through `pod install`, the Gradle
  config block, and the first `DVAIBridge.start(...)` call.

If you're contributing to `@dvai-bridge/react-native` itself and want to
exercise the bridge end-to-end against a real RN host app, the recommended
flow is:

1. `npx @react-native-community/cli init MyDvaiApp` (Bridgeless ON
   default; pin RN to ≥ 0.77).
2. In `MyDvaiApp/package.json`, add a `file:` dependency to this package:

   ```json
   "dependencies": {
     "@dvai-bridge/react-native": "file:../../packages/dvai-bridge-react-native"
   }
   ```

3. `cd MyDvaiApp/ios && pod install`.
4. `npm run ios` — the pod's TurboModule registration kicks in at boot.

The same shape works on Android via `npx react-native run-android` after
adding the GitHub Packages Maven repo block from the SDK guide.
