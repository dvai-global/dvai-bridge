// DVAIBridgeNative.mm
//
// React Native TurboModule registration glue. The actual implementation
// lives in `DVAIBridgeNative.swift` (Swift -> Obj-C interop via @objc).
//
// `RCT_EXTERN_MODULE` is the standard RN macro for exposing a Swift class
// to the bridge. We follow it with `RCT_EXTERN_METHOD` lines that mirror
// the `Spec` interface in `src/NativeDVAIBridge.ts`. Codegen consumes
// `Spec` at `pod install` time and emits the C++ TurboModule stubs that
// dispatch into these methods.

#import "DVAIBridgeNative.h"

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

#ifdef RCT_NEW_ARCH_ENABLED
#import "RNDVAIBridgeSpec.h"
#endif

@interface RCT_EXTERN_REMAP_MODULE(DVAIBridge, DVAIBridgeNative, RCTEventEmitter)

// Promise-returning lifecycle methods. Each forwards to a Swift @objc
// instance method named `bridgeStartWithOpts:resolver:rejecter:` (etc.).
RCT_EXTERN_METHOD(startBridge:(NSDictionary *)opts
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(stopBridge:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(status:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(downloadModel:(NSDictionary *)opts
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

// `RCTEventEmitter` already declares `addListener:` / `removeListeners:`,
// but RN ≥ 0.65 expects subclasses to re-export them via RCT_EXTERN_METHOD
// so the JS side's NativeEventEmitter housekeeping resolves cleanly.
RCT_EXTERN_METHOD(addListener:(NSString *)eventName)
RCT_EXTERN_METHOD(removeListeners:(double)count)

+ (BOOL)requiresMainQueueSetup
{
    return NO;
}

@end
