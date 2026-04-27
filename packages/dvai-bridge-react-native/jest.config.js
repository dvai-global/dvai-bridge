/**
 * Jest configuration for `@dvai-bridge/react-native`.
 *
 * The package is a tiny TS facade around an RN TurboModule, so the test
 * surface is purely the JS-side logic: platform-specific BackendKind
 * validation, error coercion, the `useDVAIBridgeState` hook's event
 * handling. The native module itself is mocked.
 *
 * We deliberately do NOT use `react-native`'s Jest preset (which pulls in
 * a metro-flavored module resolver, native shim setup, and a few transform
 * passes we don't need for unit tests of pure-JS facade code). Instead we
 * use a plain `babel-jest` transform with the package's babel.config.js
 * and a per-test mock of the `react-native` module.
 *
 * `testEnvironment: "jsdom"` is required for the `useDVAIBridgeState` hook
 * test (it renders a tiny consumer component via `@testing-library/react-native`).
 */

module.exports = {
  preset: undefined,
  testEnvironment: "jsdom",
  testMatch: [
    "<rootDir>/src/**/__tests__/**/*.test.ts",
    "<rootDir>/src/**/__tests__/**/*.test.tsx",
  ],
  transform: {
    "^.+\\.(ts|tsx|js|jsx)$": ["babel-jest", { configFile: "./babel.config.js" }],
  },
  transformIgnorePatterns: [
    "node_modules/(?!(react-native|@react-native|@react-native-community)/)",
  ],
  moduleFileExtensions: ["ts", "tsx", "js", "jsx", "json"],
  setupFiles: ["<rootDir>/jest.setup.js"],
  // Speed up: skip building lib/ when running tests.
  testPathIgnorePatterns: ["/node_modules/", "/lib/"],
  clearMocks: true,
  // Avoid collecting from generated/lib.
  collectCoverageFrom: ["src/**/*.{ts,tsx}", "!src/**/__tests__/**", "!src/**/*.d.ts"],
};
