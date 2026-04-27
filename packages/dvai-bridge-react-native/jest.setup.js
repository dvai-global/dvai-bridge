/**
 * Jest setup — global mocks for the `react-native` module surface that
 * `@dvai-bridge/react-native` touches:
 *
 *  - `Platform.OS`: per-test override via `(require('react-native').Platform.OS = 'ios')`.
 *  - `TurboModuleRegistry.getEnforcing`: returns the test mock module.
 *  - `NativeEventEmitter`: minimal in-memory event bus.
 *  - `NativeModules.DVAIBridge`: same mock as the TurboModule.
 *
 * Tests can override individual mock methods via
 *   require('./src/NativeDVAIBridge').default.<method>.mockResolvedValue(...).
 */

jest.mock("react-native", () => {
  const listeners = new Map();

  const mockNativeModule = {
    startBridge: jest.fn(),
    stopBridge: jest.fn(),
    status: jest.fn(),
    downloadModel: jest.fn(),
    addListener: jest.fn(),
    removeListeners: jest.fn(),
  };

  class NativeEventEmitter {
    constructor() {}
    addListener(eventName, listener) {
      const arr = listeners.get(eventName) ?? [];
      arr.push(listener);
      listeners.set(eventName, arr);
      return {
        remove: () => {
          const current = listeners.get(eventName) ?? [];
          listeners.set(
            eventName,
            current.filter((fn) => fn !== listener),
          );
        },
      };
    }
    removeAllListeners(eventName) {
      listeners.delete(eventName);
    }
    emit(eventName, payload) {
      (listeners.get(eventName) ?? []).forEach((fn) => fn(payload));
    }
  }

  // Expose the mock on the `react-native` module so individual tests can
  // dispatch fake events via `require("react-native").__emit(...)`.
  const __emit = (eventName, payload) => {
    (listeners.get(eventName) ?? []).forEach((fn) => fn(payload));
  };
  const __resetListeners = () => listeners.clear();

  return {
    Platform: { OS: "ios", select: (specifics) => specifics.ios ?? specifics.default },
    NativeEventEmitter,
    NativeModules: { DVAIBridge: mockNativeModule },
    TurboModuleRegistry: {
      getEnforcing: jest.fn(() => mockNativeModule),
      get: jest.fn(() => mockNativeModule),
    },
    __mockNativeModule: mockNativeModule,
    __emit,
    __resetListeners,
  };
});
