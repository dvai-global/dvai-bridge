import { vi } from 'vitest';

const listeners = new Map();

export const mockNativeModule = {
  startBridge: vi.fn(),
  stopBridge: vi.fn(),
  status: vi.fn(),
  downloadModel: vi.fn(),
  respondToPairing: vi.fn(),
  addListener: vi.fn(),
  removeListeners: vi.fn(),
};

export class NativeEventEmitter {
  constructor() {}
  addListener(eventName: string, listener: any) {
    const arr = listeners.get(eventName) ?? [];
    arr.push(listener);
    listeners.set(eventName, arr);
    return {
      remove: () => {
        const current = listeners.get(eventName) ?? [];
        listeners.set(
          eventName,
          current.filter((fn: any) => fn !== listener),
        );
      },
    };
  }
  removeAllListeners(eventName: string) {
    listeners.delete(eventName);
  }
  emit(eventName: string, payload: any) {
    (listeners.get(eventName) ?? []).forEach((fn: any) => fn(payload));
  }
}

export const Platform = {
  OS: "ios",
  select: (specifics: any) => specifics.ios ?? specifics.default,
};

export const NativeModules = {
  DVAIBridge: mockNativeModule,
};

export const TurboModuleRegistry = {
  getEnforcing: vi.fn(() => mockNativeModule),
  get: vi.fn(() => mockNativeModule),
};

export const __mockNativeModule = mockNativeModule;
export const __emit = (eventName: string, payload: any) => {
  (listeners.get(eventName) ?? []).forEach((fn: any) => fn(payload));
};
export const __resetListeners = () => listeners.clear();

export default {
  Platform,
  NativeEventEmitter,
  NativeModules,
  TurboModuleRegistry,
  __mockNativeModule,
  __emit,
  __resetListeners,
};
