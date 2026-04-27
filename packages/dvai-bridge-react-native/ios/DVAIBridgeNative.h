// DVAIBridgeNative.h
//
// Public Obj-C header for the React Native TurboModule bridge that wraps
// the `DVAIBridge` Swift umbrella (Phase 3C v2.1). Required by RN's New
// Architecture so the TurboModule can be registered with the C++ runtime
// from `DVAIBridgeNative.mm`.
//
// The module exposes itself to JS as `"DVAIBridge"` (matching the
// `TurboModuleRegistry.getEnforcing<Spec>("DVAIBridge")` lookup in
// `src/NativeDVAIBridge.ts`).
//
// Progress events emit on the `"DVAIBridgeProgress"` channel — matched by
// `src/DVAIBridge.ts`'s `NativeEventEmitter` setup.

#import <Foundation/Foundation.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

NS_ASSUME_NONNULL_BEGIN

// The Obj-C-visible class. The Swift implementation is in
// `DVAIBridgeNative.swift`; the `@objc` annotations there make every
// method discoverable from this declaration.
//
// Subclassing `RCTEventEmitter` rather than just conforming to
// `RCTBridgeModule` lets us emit `DVAIBridgeProgress` events from Swift
// via `sendEventWithName:body:`. The event name is also declared in
// `+supportedEvents` (in the Swift impl).
@interface DVAIBridgeNative : RCTEventEmitter <RCTBridgeModule>
@end

NS_ASSUME_NONNULL_END
