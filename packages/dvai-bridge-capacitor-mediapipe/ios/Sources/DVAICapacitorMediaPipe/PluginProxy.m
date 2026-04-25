#import <Foundation/Foundation.h>

#if __has_include(<Capacitor/Capacitor.h>)
#import <Capacitor/Capacitor.h>

CAP_PLUGIN(DVAIBridgeMediaPipePlugin, "DVAIBridgeMediaPipe",
    CAP_PLUGIN_METHOD(start, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(stop, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(status, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(downloadModel, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(listCachedModels, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(deleteCachedModel, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(cacheDir, CAPPluginReturnPromise);
)
#endif
