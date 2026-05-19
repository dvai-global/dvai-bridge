// Test-only augmentation for the `react-native` module.
//
// Tests use `vi.mock('react-native', () => ({ ..., __mockNativeModule,
// __emit, __resetListeners }))` to replace RN at runtime with a fake
// that exposes these inspection hooks. Upstream `react-native` types
// don't declare them, so tsc rejects `RN.__mockNativeModule.*`
// references with TS2551. Augmenting the module here teaches tsc that
// these symbols exist at type-check time; at runtime the vi.mock
// replacement is what actually provides them.
//
// This file is a MODULE (has `export {}` at the bottom), which is what
// makes `declare module "react-native"` operate as augmentation rather
// than as a fresh ambient declaration that would shadow RN's real
// types. See globals.d.ts for the script-mode sibling that handles
// react-test-renderer.
type DVAIMock = import("vitest").Mock;

interface DVAIMockNativeModule {
  startBridge: DVAIMock;
  stopBridge: DVAIMock;
  status: DVAIMock;
  downloadModel: DVAIMock;
  respondToPairing: DVAIMock;
  addListener: DVAIMock;
  removeListeners: DVAIMock;
  // Some tests extend the mock with assessHardware; declare it so
  // refactors can drop the `!` non-null assertion if/when they grow.
  assessHardware: DVAIMock;
}

declare module "react-native" {
  export const __mockNativeModule: DVAIMockNativeModule;
  export const __emit: (eventName: string, payload: unknown) => void;
  export const __resetListeners: () => void;
}

export {};
