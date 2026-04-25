# Phase 1 Capacitor Multimodal Implementation Plan — Part 2

> **Continued from:** [`2026-04-25-phase1-capacitor-multimodal.md`](./2026-04-25-phase1-capacitor-multimodal.md) (Part 1, Tasks 1-27)

**Tasks 28-56:** complete `capacitor-llama`, then `capacitor-foundation`, `capacitor-mediapipe`, docs, CI, final verification.

---

## Phase 1D continued — `@dvai-bridge/capacitor-llama` (Tasks 28-37)

### Task 28: iOS lifecycle wiring (`Plugin.swift` → `HttpServer` + handlers)

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Plugin.swift`
- Create: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/PluginState.swift`

- [ ] **Step 1: Write `PluginState.swift` to hold the running state**

```swift
// Internal/PluginState.swift
import Foundation
import Telegraph

actor PluginState {
    private var server: HttpServer?
    private var bridge: LlamaCppBridge?
    private(set) var modelId: String = ""
    private(set) var isRunning: Bool = false
    private(set) var baseUrl: String?
    private(set) var port: Int?

    func start(opts: [String: Any]) async throws -> [String: Any] {
        if isRunning { try await stop() }

        guard let modelPath = opts["modelPath"] as? String, !modelPath.isEmpty else {
            throw NSError(domain: "DVAIBridgeLlama", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "modelPath is required for llama backend"])
        }
        let mmprojPath = opts["mmprojPath"] as? String
        let gpuLayers = opts["gpuLayers"] as? Int ?? 99
        let contextSize = opts["contextSize"] as? Int ?? 2048
        let threads = opts["threads"] as? Int ?? 4
        let embeddingMode = opts["embeddingMode"] as? Bool ?? false
        let httpBasePort = opts["httpBasePort"] as? Int ?? 38883
        let httpMaxPortAttempts = opts["httpMaxPortAttempts"] as? Int ?? 16
        let corsOrigin = opts["corsOrigin"]

        // Load model
        let bridge = LlamaCppBridge()
        var error: NSError?
        if !bridge.loadModel(atPath: modelPath, mmprojPath: mmprojPath,
                             gpuLayers: Int32(gpuLayers), contextSize: Int32(contextSize),
                             threads: Int32(threads), embeddingMode: embeddingMode,
                             error: &error) {
            throw error ?? NSError(domain: "DVAIBridgeLlama", code: 500,
                                   userInfo: [NSLocalizedDescriptionKey: "Model load failed"])
        }

        // Start server
        let server = HttpServer()
        let port = try await server.tryBind(basePort: httpBasePort,
                                            maxAttempts: httpMaxPortAttempts,
                                            host: "127.0.0.1")

        // Wire handlers
        let handlers = LlamaHandlers(bridge: bridge, modelId: modelPath)
        let cfg = DispatchConfig(corsOrigin: parseCors(corsOrigin))
        let ctx = HandlerContext(modelId: modelPath, backendName: "llama")
        await server.installRoutes(handlers: handlers, ctx: ctx, config: cfg)

        self.server = server
        self.bridge = bridge
        self.modelId = modelPath
        self.port = port
        self.baseUrl = "http://127.0.0.1:\(port)/v1"
        self.isRunning = true

        return [
            "baseUrl": self.baseUrl!,
            "port": port,
            "backend": "llama",
            "modelId": modelPath,
        ]
    }

    func stop() async throws {
        await server?.stop()
        bridge?.unload()
        server = nil
        bridge = nil
        isRunning = false
        baseUrl = nil
        port = nil
    }

    func statusInfo() -> [String: Any] {
        var dict: [String: Any] = ["running": isRunning]
        if let baseUrl = baseUrl { dict["baseUrl"] = baseUrl }
        if isRunning { dict["backend"] = "llama" }
        return dict
    }

    private func parseCors(_ raw: Any?) -> DispatchConfig.CORSConfig {
        if let s = raw as? String { return s == "*" ? .wildcard : .exact(s) }
        if let arr = raw as? [String] { return .allowlist(arr) }
        return .wildcard
    }
}
```

- [ ] **Step 2: Wire Plugin.swift to PluginState**

```swift
// Plugin.swift (replace skeleton implementations)
import Foundation
import Capacitor

@objc(DVAIBridgeLlamaPlugin)
public class DVAIBridgeLlamaPlugin: CAPPlugin {
    private let state = PluginState()

    @objc func start(_ call: CAPPluginCall) {
        let opts = call.options ?? [:]
        Task {
            do {
                let result = try await state.start(opts: opts)
                call.resolve(result)
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        Task {
            try? await state.stop()
            call.resolve()
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        Task {
            let info = await state.statusInfo()
            call.resolve(info)
        }
    }

    // downloadModel/listCachedModels/deleteCachedModel/cacheDir wired in Task 32
}
```

- [ ] **Step 3: Add a stub LlamaHandlers so it compiles** (full impl in Task 36)

Create `Sources/DVAICapacitorLlama/LlamaHandlers.swift`:

```swift
import Foundation

public final class LlamaHandlers: DVAIHandlers {
    private let bridge: LlamaCppBridge
    private let modelId: String

    public init(bridge: LlamaCppBridge, modelId: String) {
        self.bridge = bridge
        self.modelId = modelId
    }

    public func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(501, ["error": "Not implemented yet — Task 36"])
    }
    public func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(501, ["error": "Not implemented yet — Task 36"])
    }
    public func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(501, ["error": "Not implemented yet — Task 36"])
    }
    public func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, [
            "object": "list",
            "data": [["id": ctx.modelId, "object": "model", "owned_by": "dvai-bridge"]]
        ])
    }
}
```

- [ ] **Step 4: Add `installRoutes` to HttpServer**

Append to `HttpServer.swift`:

```swift
extension HttpServer {
    func installRoutes(handlers: DVAIHandlers, ctx: HandlerContext, config: DispatchConfig) async {
        guard let s = server else { return }
        let dispatch: (HTTPRequest) async -> HTTPResponse = { request in
            await dispatchRoute(request: request, handlers: handlers, ctx: ctx, config: config)
        }
        // Telegraph 0.30: route by method + path or wildcard
        s.route(.OPTIONS, "*", dispatch)
        s.route(.POST, "/v1/chat/completions", dispatch)
        s.route(.POST, "/v1/completions", dispatch)
        s.route(.POST, "/v1/embeddings", dispatch)
        s.route(.GET, "/v1/models", dispatch)
        // 404 fallback
        s.route(.unknown, "*", dispatch)
    }
}
```

- [ ] **Step 5: Run iOS build + tests on Mac**

```bash
ssh mac "cd /Users/zer0/Developer/dvai-bridge && git pull && cd packages/dvai-bridge-capacitor-llama/ios && swift build"
```

Expected: builds clean (warnings about Telegraph API minor differences are OK).

- [ ] **Step 6: Commit on Mac**

```bash
ssh mac "cd /Users/zer0/Developer/dvai-bridge && git add . && git commit -m 'feat(capacitor-llama,ios): wire start/stop lifecycle through PluginState' && git push"
git pull
```

### Task 29: Android lifecycle wiring (`Plugin.kt` → `HttpServer` + handlers)

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/Plugin.kt`
- Create: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/PluginState.kt`
- Create: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/LlamaHandlers.kt` (stub)
- Create: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/HandlerDispatch.kt`

- [ ] **Step 1: Write `HandlerDispatch.kt`** (parallel to iOS Task 27)

```kotlin
package co.deepvoiceai.dvaibridge.llama

import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.response.*
import io.ktor.server.request.*
import io.ktor.server.routing.*
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.*

data class HandlerContext(val modelId: String, val backendName: String)

sealed class HandlerResponse {
    data class Json(val status: Int, val body: JsonElement) : HandlerResponse()
    data class Sse(val flow: Flow<String>) : HandlerResponse()
    data class Error(val status: Int, val message: String) : HandlerResponse()
}

interface DvaiHandlers {
    suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleModels(ctx: HandlerContext): HandlerResponse
}

sealed class CorsConfig {
    object Wildcard : CorsConfig()
    data class Exact(val origin: String) : CorsConfig()
    data class Allowlist(val origins: List<String>) : CorsConfig()

    fun headerValue(reqOrigin: String?): String? = when (this) {
        is Wildcard -> "*"
        is Exact -> origin
        is Allowlist -> if (reqOrigin != null && origins.contains(reqOrigin)) reqOrigin else null
    }
}

fun applyCors(call: ApplicationCall, config: CorsConfig) {
    call.response.headers.append("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
    call.response.headers.append("Access-Control-Allow-Headers", "Content-Type, Authorization")
    call.response.headers.append("Access-Control-Allow-Private-Network", "true")
    config.headerValue(call.request.header("Origin"))?.let {
        call.response.headers.append("Access-Control-Allow-Origin", it)
    }
}

fun Routing.installDispatchRoutes(handlers: DvaiHandlers, ctx: HandlerContext, config: CorsConfig) {
    options("{...}") {
        applyCors(call, config)
        call.respond(HttpStatusCode.NoContent)
    }
    post("/v1/chat/completions") {
        applyCors(call, config)
        val body = parseBody(call.receiveText())
        respondWithHandlerResponse(call, handlers.handleChatCompletion(body, ctx), config)
    }
    post("/v1/completions") {
        applyCors(call, config)
        val body = parseBody(call.receiveText())
        respondWithHandlerResponse(call, handlers.handleCompletion(body, ctx), config)
    }
    post("/v1/embeddings") {
        applyCors(call, config)
        val body = parseBody(call.receiveText())
        respondWithHandlerResponse(call, handlers.handleEmbeddings(body, ctx), config)
    }
    get("/v1/models") {
        applyCors(call, config)
        respondWithHandlerResponse(call, handlers.handleModels(ctx), config)
    }
}

private fun parseBody(raw: String): JsonObject {
    if (raw.isBlank()) return JsonObject(emptyMap())
    return Json.parseToJsonElement(raw) as JsonObject
}

private suspend fun respondWithHandlerResponse(
    call: ApplicationCall,
    response: HandlerResponse,
    config: CorsConfig,
) {
    when (response) {
        is HandlerResponse.Json -> {
            call.respondText(
                response.body.toString(),
                ContentType.Application.Json,
                HttpStatusCode.fromValue(response.status),
            )
        }
        is HandlerResponse.Sse -> {
            call.response.headers.append(HttpHeaders.ContentType, ContentType.Text.EventStream.toString())
            call.response.headers.append(HttpHeaders.CacheControl, "no-cache")
            call.respondTextWriter(ContentType.Text.EventStream) {
                response.flow.collect { chunk ->
                    write(chunk)
                    flush()
                }
            }
        }
        is HandlerResponse.Error -> {
            call.respondText(
                buildJsonObject { put("error", response.message) }.toString(),
                ContentType.Application.Json,
                HttpStatusCode.fromValue(response.status),
            )
        }
    }
}
```

- [ ] **Step 2: Write a stub `LlamaHandlers.kt`** (full impl in Task 36)

```kotlin
// LlamaHandlers.kt
package co.deepvoiceai.dvaibridge.llama

import kotlinx.serialization.json.*

class LlamaHandlers(
    private val bridge: LlamaCppBridge,
    private val modelId: String,
) : DvaiHandlers {
    override suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse {
        return HandlerResponse.Json(
            501,
            buildJsonObject { put("error", "Not implemented yet — Task 36") },
        )
    }
    override suspend fun handleCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(501, buildJsonObject { put("error", "Not implemented yet — Task 36") })
    override suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(501, buildJsonObject { put("error", "Not implemented yet — Task 36") })
    override suspend fun handleModels(ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(
            200,
            buildJsonObject {
                put("object", "list")
                putJsonArray("data") {
                    addJsonObject {
                        put("id", ctx.modelId)
                        put("object", "model")
                        put("owned_by", "dvai-bridge")
                    }
                }
            },
        )
}
```

- [ ] **Step 3: Update `HttpServer.kt` to install routes**

Add to `HttpServer.kt`:

```kotlin
import io.ktor.server.application.*
import io.ktor.server.routing.*

class HttpServer {
    // ...existing tryBind / stop...

    suspend fun startWithRoutes(
        basePort: Int,
        maxAttempts: Int,
        host: String,
        handlers: DvaiHandlers,
        ctx: HandlerContext,
        corsConfig: CorsConfig,
    ): Int {
        for (i in 0 until maxAttempts) {
            val port = basePort + i
            try {
                val s = embeddedServer(io.ktor.server.cio.CIO, port = port, host = host) {
                    routing { installDispatchRoutes(handlers, ctx, corsConfig) }
                }
                s.start(wait = false)
                this.server = s
                this.boundPort = port
                kotlinx.coroutines.delay(50)
                return port
            } catch (e: Exception) { continue }
        }
        throw IllegalStateException("All ports blocked in $basePort..${basePort + maxAttempts - 1}")
    }
}
```

- [ ] **Step 4: Write `PluginState.kt`**

```kotlin
package co.deepvoiceai.dvaibridge.llama

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.getcapacitor.JSObject

class PluginState {
    private val mutex = Mutex()
    private var server: HttpServer? = null
    private var bridge: LlamaCppBridge? = null
    private var modelId: String = ""
    private var isRunning: Boolean = false
    private var baseUrl: String? = null
    private var port: Int? = null

    suspend fun start(opts: JSObject): JSObject = mutex.withLock {
        if (isRunning) stopInternal()

        val modelPath = opts.getString("modelPath") ?: throw IllegalArgumentException("modelPath required")
        val mmprojPath = opts.getString("mmprojPath")
        val gpuLayers = opts.getInteger("gpuLayers") ?: 99
        val contextSize = opts.getInteger("contextSize") ?: 2048
        val threads = opts.getInteger("threads") ?: 4
        val embeddingMode = opts.getBoolean("embeddingMode", false) ?: false
        val httpBasePort = opts.getInteger("httpBasePort") ?: 38883
        val httpMaxPortAttempts = opts.getInteger("httpMaxPortAttempts") ?: 16

        val corsRaw = opts.opt("corsOrigin")
        val cors = parseCors(corsRaw)

        val bridge = LlamaCppBridge()
        if (!bridge.loadModel(modelPath, mmprojPath, gpuLayers, contextSize, threads, embeddingMode)) {
            throw IllegalStateException("Failed to load model at $modelPath")
        }

        val handlers = LlamaHandlers(bridge, modelPath)
        val ctx = HandlerContext(modelId = modelPath, backendName = "llama")

        val server = HttpServer()
        val port = server.startWithRoutes(httpBasePort, httpMaxPortAttempts, "127.0.0.1", handlers, ctx, cors)

        this.server = server
        this.bridge = bridge
        this.modelId = modelPath
        this.port = port
        this.baseUrl = "http://127.0.0.1:$port/v1"
        this.isRunning = true

        return JSObject().apply {
            put("baseUrl", baseUrl)
            put("port", port)
            put("backend", "llama")
            put("modelId", modelPath)
        }
    }

    suspend fun stop() = mutex.withLock { stopInternal() }

    private suspend fun stopInternal() {
        server?.stop()
        bridge?.unload()
        server = null
        bridge = null
        isRunning = false
        baseUrl = null
        port = null
    }

    fun statusInfo(): JSObject = JSObject().apply {
        put("running", isRunning)
        baseUrl?.let { put("baseUrl", it) }
        if (isRunning) put("backend", "llama")
    }

    private fun parseCors(raw: Any?): CorsConfig = when (raw) {
        is String -> if (raw == "*") CorsConfig.Wildcard else CorsConfig.Exact(raw)
        is List<*> -> CorsConfig.Allowlist(raw.filterIsInstance<String>())
        else -> CorsConfig.Wildcard
    }
}
```

- [ ] **Step 5: Wire `Plugin.kt` to PluginState**

```kotlin
@CapacitorPlugin(name = "DVAIBridgeLlama")
class DVAIBridgeLlamaPlugin : Plugin() {
    private val state = PluginState()

    @PluginMethod
    fun start(call: PluginCall) {
        val opts = call.data
        kotlinx.coroutines.GlobalScope.launch {
            try {
                val result = state.start(opts)
                call.resolve(result)
            } catch (e: Exception) {
                call.reject(e.message ?: "Start failed", e)
            }
        }
    }

    @PluginMethod
    fun stop(call: PluginCall) {
        kotlinx.coroutines.GlobalScope.launch {
            try { state.stop(); call.resolve() }
            catch (e: Exception) { call.reject(e.message ?: "Stop failed", e) }
        }
    }

    @PluginMethod
    fun status(call: PluginCall) { call.resolve(state.statusInfo()) }

    // downloadModel/listCachedModels/deleteCachedModel/cacheDir wired in Task 32
}
```

- [ ] **Step 6: Run Android tests + build**

```bash
cd packages/dvai-bridge-capacitor-llama/android && ./gradlew test assembleDebug
```

Expected: tests pass; debug AAR builds.

- [ ] **Step 7: Commit**

```bash
git add packages/dvai-bridge-capacitor-llama/android/
git commit -m "feat(capacitor-llama,android): wire start/stop lifecycle through PluginState"
```

### Task 30: Real `LlamaCppBridge` calling llama.cpp on iOS

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/LlamaCppBridge.{h,mm}`

- [ ] **Step 1: Replace the stub `.mm` with real llama.cpp calls**

```objc
// LlamaCppBridge.mm
#import "LlamaCppBridge.h"
#import "llama.h"
#import <Foundation/Foundation.h>

@implementation LlamaCppBridge {
    struct llama_model *_model;
    struct llama_context *_ctx;
    NSString *_currentModelPath;
    BOOL _embeddingMode;
}

- (instancetype)init {
    if ((self = [super init])) {
        _model = NULL;
        _ctx = NULL;
        _currentModelPath = nil;
        _embeddingMode = NO;
    }
    return self;
}

- (void)dealloc { [self unload]; }

- (BOOL)isLoaded { return _model != NULL && _ctx != NULL; }
- (NSString *)currentModelPath { return _currentModelPath; }

- (BOOL)loadModelAtPath:(NSString *)path
              mmprojPath:(NSString *)mmprojPath
              gpuLayers:(int)gpuLayers
            contextSize:(int)contextSize
                threads:(int)threads
          embeddingMode:(BOOL)embeddingMode
                  error:(NSError **)error {
    if (path.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"DVAIBridgeLlama" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"empty model path"}];
        return NO;
    }
    [self unload];

    llama_backend_init();

    struct llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpuLayers;
    _model = llama_load_model_from_file([path UTF8String], mp);
    if (_model == NULL) {
        if (error) *error = [NSError errorWithDomain:@"DVAIBridgeLlama" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"llama_load_model_from_file failed"}];
        return NO;
    }

    struct llama_context_params cp = llama_context_default_params();
    cp.n_ctx = contextSize;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    cp.embeddings = embeddingMode ? true : false;
    _ctx = llama_new_context_with_model(_model, cp);
    if (_ctx == NULL) {
        llama_free_model(_model); _model = NULL;
        if (error) *error = [NSError errorWithDomain:@"DVAIBridgeLlama" code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"llama_new_context_with_model failed"}];
        return NO;
    }

    // mmproj loading: if provided, load multimodal projector via llama.cpp's mtmd API.
    // (mtmd_helper_eval API surfaces evolve quickly. Wire the actual call when binding the
    // multimodal pipeline in Task 35.)
    if (mmprojPath.length > 0) {
        // Stash for later — mmproj loading happens inside the multimodal eval path.
        // We just record the path; ContentPartsTranslator picks it up.
    }

    _currentModelPath = [path copy];
    _embeddingMode = embeddingMode;
    return YES;
}

- (void)unload {
    if (_ctx) { llama_free(_ctx); _ctx = NULL; }
    if (_model) { llama_free_model(_model); _model = NULL; }
    _currentModelPath = nil;
    _embeddingMode = NO;
}

- (NSString *)versionString {
    return [NSString stringWithFormat:@"llama.cpp %s", llama_print_system_info()];
}

// Token generation API for use by LlamaHandlers (Task 36)
- (nullable NSString *)completePrompt:(NSString *)prompt
                            maxTokens:(int)maxTokens
                          temperature:(float)temperature
                                topP:(float)topP
                               error:(NSError **)error {
    if (!self.isLoaded) {
        if (error) *error = [NSError errorWithDomain:@"DVAIBridgeLlama" code:10
                                            userInfo:@{NSLocalizedDescriptionKey: @"Model not loaded"}];
        return nil;
    }
    // Tokenize prompt
    const char *cprompt = [prompt UTF8String];
    int n_tokens = (int)strlen(cprompt) + 1;
    int *tokens = (int *)calloc((size_t)n_tokens, sizeof(int));
    int actual = llama_tokenize(_model, cprompt, (int)strlen(cprompt),
                                tokens, n_tokens, true, false);
    if (actual < 0) {
        free(tokens);
        if (error) *error = [NSError errorWithDomain:@"DVAIBridgeLlama" code:11
                                            userInfo:@{NSLocalizedDescriptionKey: @"Tokenization failed"}];
        return nil;
    }

    // Eval batch
    struct llama_batch batch = llama_batch_get_one(tokens, actual, 0, 0);
    if (llama_decode(_ctx, batch) != 0) {
        free(tokens);
        if (error) *error = [NSError errorWithDomain:@"DVAIBridgeLlama" code:12
                                            userInfo:@{NSLocalizedDescriptionKey: @"Decode failed"}];
        return nil;
    }
    free(tokens);

    // Sample tokens
    NSMutableString *result = [NSMutableString string];
    int n_predict = maxTokens;
    int n_cur = actual;

    for (int i = 0; i < n_predict; i++) {
        struct llama_token_data_array candidates = { 0 };
        // Simplified greedy sampling — production code would use temperature sampling.
        int new_token_id = llama_sample_token_greedy(_ctx, &candidates);

        if (new_token_id == llama_token_eos(_model)) break;

        char buf[256] = {0};
        int n = llama_token_to_piece(_model, new_token_id, buf, sizeof(buf), 0, false);
        if (n > 0) {
            [result appendString:[NSString stringWithUTF8String:buf]];
        }

        struct llama_batch nb = llama_batch_get_one(&new_token_id, 1, n_cur, 0);
        if (llama_decode(_ctx, nb) != 0) break;
        n_cur++;
    }

    return result;
}

@end
```

> Note on llama.cpp's API stability: function names like `llama_sample_token_greedy`, `llama_tokenize`, etc. shift between versions. The exact API for the pinned SHA needs verification. Run `swift build` and fix any signature mismatches against the version in `native/llama.cpp/include/llama.h`. The structure is correct; specific function names may need tweaks.

- [ ] **Step 2: Update `LlamaCppBridge.h` to expose `completePrompt:`**

Add to the interface in the .h:

```objc
- (nullable NSString *)completePrompt:(NSString *)prompt
                            maxTokens:(int)maxTokens
                          temperature:(float)temperature
                                topP:(float)topP
                               error:(NSError **)error;
```

- [ ] **Step 3: Build via Mac**

```bash
ssh mac "cd /Users/zer0/Developer/dvai-bridge && git pull && cd packages/dvai-bridge-capacitor-llama/ios && swift build 2>&1 | tail -40"
```

Expected: builds. If llama.cpp's API has different function names than the ones used here, the compiler will tell you. Fix the calls to match what's in `native/llama.cpp/include/llama.h`.

- [ ] **Step 4: Run existing tests**

```bash
ssh mac "cd /Users/zer0/Developer/dvai-bridge/packages/dvai-bridge-capacitor-llama/ios && swift test"
```

Expected: existing tests still pass (the stub was replaced with real impl; load/unload/path checks still work the same way).

- [ ] **Step 5: Commit on Mac**

```bash
ssh mac "cd /Users/zer0/Developer/dvai-bridge && git add . && git commit -m 'feat(capacitor-llama,ios): real llama.cpp bridge via ObjC++' && git push"
git pull
```

### Task 31: Real `LlamaCppBridge` calling llama.cpp on Android

**Files:**
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/cpp/jni-bridge.cpp`
- Modify: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/LlamaCppBridge.kt`

- [ ] **Step 1: Replace `jni-bridge.cpp` with real JNI methods**

```cpp
// android/src/main/cpp/jni-bridge.cpp
#include <jni.h>
#include <string>
#include <vector>
#include <android/log.h>
#include "llama.h"

#define LOG_TAG "DVAIBridgeLlama"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

struct LlamaContextHolder {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    std::string model_path;
    bool embedding_mode = false;
};

extern "C" JNIEXPORT jlong JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeCreate(JNIEnv* env, jobject thiz) {
    return (jlong)(new LlamaContextHolder());
}

extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeDestroy(JNIEnv* env, jobject thiz, jlong handle) {
    auto* h = (LlamaContextHolder*)handle;
    if (!h) return;
    if (h->ctx) llama_free(h->ctx);
    if (h->model) llama_free_model(h->model);
    delete h;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeLoadModel(
    JNIEnv* env, jobject thiz, jlong handle,
    jstring jPath, jstring jMmprojPath,
    jint gpuLayers, jint contextSize, jint threads, jboolean embeddingMode) {
    auto* h = (LlamaContextHolder*)handle;
    if (!h) return JNI_FALSE;

    if (h->ctx) { llama_free(h->ctx); h->ctx = nullptr; }
    if (h->model) { llama_free_model(h->model); h->model = nullptr; }

    const char* cPath = env->GetStringUTFChars(jPath, nullptr);
    h->model_path = cPath;
    env->ReleaseStringUTFChars(jPath, cPath);

    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = gpuLayers;
    h->model = llama_load_model_from_file(h->model_path.c_str(), mp);
    if (!h->model) { LOGE("load_model_from_file failed"); return JNI_FALSE; }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = contextSize;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    cp.embeddings = (embeddingMode == JNI_TRUE);
    h->ctx = llama_new_context_with_model(h->model, cp);
    if (!h->ctx) {
        LOGE("new_context_with_model failed");
        llama_free_model(h->model); h->model = nullptr;
        return JNI_FALSE;
    }
    h->embedding_mode = (embeddingMode == JNI_TRUE);
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeUnload(JNIEnv* env, jobject thiz, jlong handle) {
    auto* h = (LlamaContextHolder*)handle;
    if (!h) return;
    if (h->ctx) { llama_free(h->ctx); h->ctx = nullptr; }
    if (h->model) { llama_free_model(h->model); h->model = nullptr; }
    h->model_path.clear();
    h->embedding_mode = false;
}

extern "C" JNIEXPORT jstring JNICALL
Java_co_deepvoiceai_dvaibridge_llama_LlamaCppBridge_nativeCompletePrompt(
    JNIEnv* env, jobject thiz, jlong handle, jstring jPrompt, jint maxTokens,
    jfloat temperature, jfloat topP) {
    auto* h = (LlamaContextHolder*)handle;
    if (!h || !h->ctx) return nullptr;

    const char* cPrompt = env->GetStringUTFChars(jPrompt, nullptr);
    std::string prompt(cPrompt);
    env->ReleaseStringUTFChars(jPrompt, cPrompt);

    // Tokenize
    std::vector<llama_token> tokens(prompt.size() + 1);
    int n = llama_tokenize(h->model, prompt.c_str(), (int)prompt.size(),
                           tokens.data(), (int)tokens.size(), true, false);
    if (n < 0) return nullptr;
    tokens.resize(n);

    llama_batch batch = llama_batch_get_one(tokens.data(), n, 0, 0);
    if (llama_decode(h->ctx, batch) != 0) return nullptr;

    // Greedy sample
    std::string out;
    int n_cur = n;
    for (int i = 0; i < maxTokens; ++i) {
        llama_token_data_array candidates = {0};
        llama_token next = llama_sample_token_greedy(h->ctx, &candidates);
        if (next == llama_token_eos(h->model)) break;

        char buf[256] = {0};
        int piece_len = llama_token_to_piece(h->model, next, buf, sizeof(buf), 0, false);
        if (piece_len > 0) out.append(buf, piece_len);

        llama_batch nb = llama_batch_get_one(&next, 1, n_cur, 0);
        if (llama_decode(h->ctx, nb) != 0) break;
        ++n_cur;
    }
    return env->NewStringUTF(out.c_str());
}
```

- [ ] **Step 2: Update Kotlin to use real JNI methods**

```kotlin
// android/src/main/java/.../LlamaCppBridge.kt
package co.deepvoiceai.dvaibridge.llama

class LlamaCppBridge {
    companion object {
        init { System.loadLibrary("dvai_capacitor_llama") }
    }

    private var nativeHandle: Long = 0
    private var loaded: Boolean = false
    private var currentModelPath: String? = null

    init {
        nativeHandle = nativeCreate()
    }

    protected fun finalize() { if (nativeHandle != 0L) nativeDestroy(nativeHandle) }

    fun isLoaded(): Boolean = loaded
    fun getCurrentModelPath(): String? = currentModelPath

    fun loadModel(
        path: String, mmprojPath: String?,
        gpuLayers: Int, contextSize: Int, threads: Int, embeddingMode: Boolean,
    ): Boolean {
        if (path.isEmpty()) return false
        val ok = nativeLoadModel(nativeHandle, path, mmprojPath, gpuLayers, contextSize, threads, embeddingMode)
        if (ok) {
            loaded = true
            currentModelPath = path
        }
        return ok
    }

    fun unload() {
        if (nativeHandle != 0L) nativeUnload(nativeHandle)
        loaded = false
        currentModelPath = null
    }

    fun completePrompt(prompt: String, maxTokens: Int, temperature: Float, topP: Float): String? {
        if (!loaded) return null
        return nativeCompletePrompt(nativeHandle, prompt, maxTokens, temperature, topP)
    }

    fun versionString(): String = "llama.cpp-android-jni-0.1"

    private external fun nativeCreate(): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeLoadModel(handle: Long, path: String, mmprojPath: String?,
                                          gpuLayers: Int, contextSize: Int, threads: Int,
                                          embeddingMode: Boolean): Boolean
    private external fun nativeUnload(handle: Long)
    private external fun nativeCompletePrompt(handle: Long, prompt: String, maxTokens: Int,
                                               temperature: Float, topP: Float): String?
}
```

- [ ] **Step 3: Build the Android library**

```bash
cd packages/dvai-bridge-capacitor-llama/android && ./gradlew assembleDebug
```

Expected: builds. May take 5-10 min on first run while llama.cpp compiles for arm64-v8a + x86_64.

- [ ] **Step 4: Run tests**

```bash
./gradlew test
```

Expected: JVM tests still pass (the JNI methods aren't loaded in JVM tests, so we test only the pure-Kotlin paths).

- [ ] **Step 5: Commit**

```bash
git add packages/dvai-bridge-capacitor-llama/android/
git commit -m "feat(capacitor-llama,android): real llama.cpp via JNI"
```

### Task 32: Model downloader (resumable + sha256 + cache) on both platforms

Lengthy but mostly mechanical. The implementation pattern is:
1. Compute destination from `<App Support>/dvai-models/<filename>` (iOS) or `<filesDir>/dvai-models/<filename>` (Android)
2. If file exists, sha256 it; if matches, return `cached: true`
3. Otherwise stream download into `.partial` with HTTP Range requests, computing sha256 incrementally
4. Verify hash; atomic rename; iOS sets `isExcludedFromBackupKey`

**Files:**
- Create: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/ModelDownloader.swift`
- Create: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/ModelDownloader.kt`
- Modify: `Plugin.swift` (wire downloadModel/listCachedModels/deleteCachedModel/cacheDir)
- Modify: `Plugin.kt` (same)
- Add tests on both platforms

- [ ] **Step 1: Write `ModelDownloader.swift`** (~150 LOC, see spec §9.3)

Key functions: `downloadModel(opts:onProgress:) async throws -> (path, cached)`, `listCachedModels() async -> [Info]`, `deleteCachedModel(filename:)`, `cacheDir() -> URL`. Implementation uses `URLSession.shared.bytes(for:)` for streaming, `CryptoKit.SHA256` for incremental hashing, `FileManager` for atomic rename.

- [ ] **Step 2: Write `ModelDownloader.kt`** (~180 LOC)

Uses OkHttp via Ktor's HTTP client (already on classpath from Ktor server dep), `MessageDigest("SHA-256")` for hash, `RandomAccessFile` for resume.

- [ ] **Step 3: Wire into Plugin.swift / Plugin.kt's `downloadModel` / `listCachedModels` / `deleteCachedModel` / `cacheDir` methods**

- [ ] **Step 4: Write fixture-based tests on both platforms**

Use a small test asset (~1 KB JSON file) hosted... actually, for unit tests, mock the HTTP layer. Test that:
- File at destination with matching sha256 → returns `cached: true` without network
- Download path: writes `.partial`, verifies hash, atomic-renames

- [ ] **Step 5: Run tests + commit**

```bash
ssh mac "cd /Users/zer0/Developer/dvai-bridge/packages/dvai-bridge-capacitor-llama/ios && swift test"
cd packages/dvai-bridge-capacitor-llama/android && ./gradlew test
git add -A
git commit -m "feat(capacitor-llama): downloadModel + cache management on both platforms"
```

### Task 33: Audio decoders (AVAudioFile + MediaCodec) — TDD

**Files:**
- Create: `packages/dvai-bridge-capacitor-llama/ios/Sources/DVAICapacitorLlama/Internal/AudioDecoder.swift`
- Create: `packages/dvai-bridge-capacitor-llama/android/src/main/java/co/deepvoiceai/dvaibridge/llama/AudioDecoder.kt`
- Create: `packages/dvai-bridge-capacitor-llama/ios/Tests/DVAICapacitorLlamaTests/AudioDecoderTest.swift`
- Create: `packages/dvai-bridge-capacitor-llama/android/src/androidTest/java/co/deepvoiceai/dvaibridge/llama/AudioDecoderInstrumentedTest.kt`

- [ ] **Step 1: Write the iOS AudioDecoder**

```swift
import Foundation
import AVFoundation

enum AudioFormat: String {
    case pcm16, wav, mp3, m4a, aac, flac
}

struct AudioDecoder {
    /// Decodes any supported audio format → 16 kHz mono PCM16 little-endian samples.
    static func decode(data: Data, format: AudioFormat) async throws -> Data {
        switch format {
        case .pcm16:
            return data
        case .wav, .mp3, .m4a, .aac, .flac:
            return try await decodeViaAVAudioFile(data: data)
        }
    }

    private static func decodeViaAVAudioFile(data: Data) async throws -> Data {
        // Write to temp file (AVAudioFile requires a file URL)
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let inputFile = try AVAudioFile(forReading: tmpURL)
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFormat)!
        let inputBuf = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: 4096)!
        let outputBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!

        var result = Data()
        while inputFile.framePosition < inputFile.length {
            try inputFile.read(into: inputBuf)
            var error: NSError?
            converter.convert(to: outputBuf, error: &error) { _, status in
                status.pointee = .haveData
                return inputBuf
            }
            if let error = error { throw error }
            if let int16Data = outputBuf.int16ChannelData {
                let frameLength = Int(outputBuf.frameLength)
                let bytes = UnsafeRawPointer(int16Data[0])
                result.append(Data(bytes: bytes, count: frameLength * 2))
            }
        }
        return result
    }
}
```

- [ ] **Step 2: Write iOS test against fixtures**

```swift
final class AudioDecoderTest: XCTestCase {
    func testPCM16PassThrough() async throws {
        let pcm = try Data(contentsOf: fixtureURL("audio/pcm16-1s-16khz-mono.bin"))
        let result = try await AudioDecoder.decode(data: pcm, format: .pcm16)
        XCTAssertEqual(result.count, pcm.count)
    }

    func testWavToPCM() async throws {
        let wav = try Data(contentsOf: fixtureURL("audio/wav-1s-16khz-mono.wav"))
        let result = try await AudioDecoder.decode(data: wav, format: .wav)
        // 1 second @ 16kHz mono = 16000 samples * 2 bytes = 32000 bytes (allow ±5%)
        XCTAssertGreaterThan(result.count, 30000)
        XCTAssertLessThan(result.count, 34000)
    }

    func testMp3ToPCM() async throws {
        let mp3 = try Data(contentsOf: fixtureURL("audio/mp3-1s.mp3"))
        let result = try await AudioDecoder.decode(data: mp3, format: .mp3)
        XCTAssertGreaterThan(result.count, 25000)
    }

    private func fixtureURL(_ relative: String) -> URL {
        Bundle.module.url(forResource: relative, withExtension: nil)!
    }
}
```

- [ ] **Step 3: Write the Android AudioDecoder using MediaExtractor + MediaCodec**

(Implementation: ~120 LOC. Read input via MediaExtractor, decode via MediaCodec to PCM16 mono 16kHz, optionally resample if input rate differs.)

- [ ] **Step 4: Write Android instrumented test** (must run on emulator since `MediaCodec` isn't available in JVM tests)

- [ ] **Step 5: Run iOS tests + Android instrumented tests**

```bash
ssh mac "cd /Users/zer0/Developer/dvai-bridge/packages/dvai-bridge-capacitor-llama/ios && swift test"
cd packages/dvai-bridge-capacitor-llama/android && ./gradlew connectedAndroidTest
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(capacitor-llama): audio decoders (AVAudioFile / MediaCodec)"
```

### Task 34: Image decoders — TDD

**Files:**
- Create: iOS `ImageDecoder.swift` (handles data URL, https:// URL, file:// URL)
- Create: Android `ImageDecoder.kt` (same)
- Add tests using the `tiny-test-base64.txt` fixture

Implementation: data URL → strip `data:image/...;base64,` prefix → base64 decode → return bytes. https:// → URLSession/OkHttp fetch with timeout. file:// → File.read.

For Phase 1, decoded images are returned as raw encoded bytes (PNG/JPEG); llama.cpp's mtmd_helper_eval handles the actual image decoding internally.

- [ ] Write decoder + tests on both platforms
- [ ] Run tests
- [ ] Commit: `feat(capacitor-llama): image decoders for data/https/file URLs`

### Task 35: ContentPartsTranslator on both platforms — TDD

**Files:**
- iOS `ContentPartsTranslator.swift` + tests
- Android `ContentPartsTranslator.kt` + tests

Behavior per spec §8: parses messages array, walks content parts, calls ImageDecoder/AudioDecoder, builds backend-specific input. Returns either a `LlamaPromptInput` struct (containing prompt text + image embeddings + audio frames) or throws TranslatorError for unsupported combinations.

Tests use `transport-fixtures.json` cases including `CHAT_REQUEST_IMAGE` and `CHAT_REQUEST_AUDIO_PCM16`.

- [ ] Write translator + tests
- [ ] Run tests
- [ ] Commit: `feat(capacitor-llama): ContentPartsTranslator on iOS + Android`

### Task 36: Real `LlamaHandlers` implementations — TDD

**Files:**
- Replace stub `LlamaHandlers.swift` (Task 28) with full impl
- Replace stub `LlamaHandlers.kt` (Task 29) with full impl
- Tests against `transport-fixtures.json`

Behavior per spec §6 / Phase 0 handlers:
- `handleChatCompletion`: extract messages → translate via ContentPartsTranslator → call bridge.completePrompt → format OpenAI response shape → if streaming, yield SSE events
- `handleCompletion`: legacy completions; convert prompt to chat; reuse chat path; convert response back to text_completion shape
- `handleEmbeddings`: if not in embedding mode, return 400; else call bridge.embedding(text) → wrap in OpenAI shape
- `handleModels`: return single-entry list with ctx.modelId

The mock-bridge tests should use a fake `LlamaCppBridge` subclass that returns canned responses (so tests don't need a real model loaded).

- [ ] Implement handlers on iOS, run `swift test`, all green
- [ ] Implement handlers on Android, run `./gradlew test`, all green
- [ ] Commit: `feat(capacitor-llama): full LlamaHandlers implementation against fixtures`

### Task 37: Phase 1D milestone — full handler-equivalence + audio + image tests pass

- [ ] **Step 1: Run full TS suite** (should still be green)

```bash
pnpm test -- --run
```

- [ ] **Step 2: Run iOS XCTest suite via Mac**

```bash
ssh mac "cd /Users/zer0/Developer/dvai-bridge/packages/dvai-bridge-capacitor-llama/ios && swift test"
```

Expected: 15-25 tests pass (smoke, port-fallback, dispatch, audio, image, translator, handlers).

- [ ] **Step 3: Run Android JVM tests + instrumented tests**

```bash
cd packages/dvai-bridge-capacitor-llama/android
./gradlew test
./gradlew connectedAndroidTest
```

Expected: similar count.

- [ ] **Step 4: Verify Capacitor pack readiness** — host app integration prep

```bash
cd packages/dvai-bridge-capacitor-llama && pnpm pack --dry-run
```

Expected: tarball includes `dist/`, `ios/Sources`, `ios/Tests`, `ios/Package.swift`, `android/src`, `android/build.gradle`, `DVAICapacitorLlama.podspec`, `README.md`. Native source ships; large compiled artifacts (`build/`, `.gradle/`) excluded.

---

## Phase 1E — `@dvai-bridge/capacitor-foundation` (Tasks 38-42)

iOS-only Apple Foundation Models plugin. Smallest plugin (~250 LOC of Swift). Reuses HTTP server + handler dispatch patterns.

### Task 38: Package scaffolding

Mirror Task 18 with `capacitor-foundation` substitution. Apple FM only, no Android. iOS Package.swift declares iOS 18.1+ deployment target. No llama.cpp submodule.

- [ ] Create `packages/dvai-bridge-capacitor-foundation/` with `package.json`, `tsconfig.json`, `tsup.config.ts`, `src/index.ts`, `README.md`, `DVAICapacitorFoundation.podspec`
- [ ] Build clean, commit: `feat(capacitor-foundation): scaffold package`

### Task 39: iOS plugin skeleton

- [ ] Create `ios/Package.swift` with iOS 18.1 platform requirement; depends on Telegraph
- [ ] Create `ios/Sources/DVAICapacitorFoundation/Plugin.swift` skeleton + `PluginProxy.m`
- [ ] Reuse Internal/ types: import `HandlerContext`, `HandlerResponse`, `DVAIHandlers` from a shared local copy (or extract to a tiny private SwiftPM module — for Phase 1, copy the file)
- [ ] Smoke test passes
- [ ] Commit on Mac: `feat(capacitor-foundation,ios): plugin skeleton`

### Task 40: Real `FoundationHandlers` implementation — TDD

```swift
import FoundationModels  // iOS 18.1+
import Foundation

@available(iOS 18.1, *)
public final class FoundationHandlers: DVAIHandlers {
    private var session: LanguageModelSession?

    public init() {}

    private func ensureSession() async throws -> LanguageModelSession {
        if let s = session { return s }
        let s = LanguageModelSession()
        session = s
        return s
    }

    public func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        let messages = body["messages"] as? [[String: Any]] ?? []
        let prompt = openAIMessagesToPrompt(messages)
        let session = try await ensureSession()

        if (body["stream"] as? Bool) == true {
            let stream = AsyncStream<String> { continuation in
                Task {
                    do {
                        for try await partial in session.responseStream(to: prompt) {
                            let chunk: [String: Any] = [
                                "id": "chatcmpl-fm",
                                "object": "chat.completion.chunk",
                                "created": Int(Date().timeIntervalSince1970),
                                "model": "apple-foundation-3b",
                                "choices": [["index": 0, "delta": ["content": partial.content], "finish_reason": NSNull()]]
                            ]
                            let json = try JSONSerialization.data(withJSONObject: chunk)
                            continuation.yield("data: \(String(data: json, encoding: .utf8)!)\n\n")
                        }
                        continuation.yield("data: [DONE]\n\n")
                        continuation.finish()
                    } catch {
                        continuation.finish()
                    }
                }
            }
            return .sse(stream)
        }

        let response = try await session.respond(to: prompt)
        return .json(200, [
            "id": "chatcmpl-fm",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": "apple-foundation-3b",
            "choices": [["index": 0, "message": ["role": "assistant", "content": response.content], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
        ])
    }

    public func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        // Reuse chat path with prompt-as-user-message conversion
        let prompt = body["prompt"] as? String ?? ""
        var chatBody = body
        chatBody["messages"] = [["role": "user", "content": prompt]]
        chatBody.removeValue(forKey: "prompt")
        return try await handleChatCompletion(body: chatBody, ctx: ctx)
    }

    public func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(400, ["error": "Embeddings not supported on Apple Foundation Models in this version."])
    }

    public func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, [
            "object": "list",
            "data": [["id": "apple-foundation-3b", "object": "model", "owned_by": "apple"]]
        ])
    }

    private func openAIMessagesToPrompt(_ messages: [[String: Any]]) -> String {
        var lines: [String] = []
        for msg in messages {
            let role = msg["role"] as? String ?? "user"
            if let text = msg["content"] as? String {
                lines.append("\(role): \(text)")
            } else if let parts = msg["content"] as? [[String: Any]] {
                for part in parts where (part["type"] as? String) == "text" {
                    lines.append("\(role): \(part["text"] as? String ?? "")")
                }
                // Image / audio parts return error — Foundation Models doesn't support them
            }
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] Tests: handleModels returns expected shape; handleEmbeddings returns 400; handleChatCompletion happy path requires real device (skip in unit tests, verify in instrumented/manual tier)
- [ ] Commit: `feat(capacitor-foundation,ios): real FoundationHandlers via LanguageModelSession`

### Task 41: Lifecycle wiring (`Plugin.swift` PluginState similar to Task 28)

- [ ] PluginState that boots HttpServer + FoundationHandlers + handler dispatch, returns baseUrl/port
- [ ] iOS-availability check: if `iOS < 18.1`, `start()` rejects with clear error
- [ ] Android stub registers but `start()` rejects: "Foundation Models is iOS-only"
- [ ] Tests + commit: `feat(capacitor-foundation): lifecycle wiring`

### Task 42: Phase 1E milestone — capacitor-foundation green

- [ ] iOS XCTest suite passes
- [ ] Build verified via `swift build`
- [ ] Pack readiness check
- [ ] Commit any cleanup

---

## Phase 1F — `@dvai-bridge/capacitor-mediapipe` (Tasks 43-49)

Android-only Google MediaPipe LLM plugin. Medium complexity (~600 LOC Kotlin).

### Task 43: Package scaffolding

Mirror Task 18 + Task 20 (Android-side only). iOS stub returns clear error.

- [ ] Create `packages/dvai-bridge-capacitor-mediapipe/` with full structure
- [ ] `android/build.gradle` adds `implementation "com.google.mediapipe:tasks-genai:0.10.14"` (or current version)
- [ ] Build, commit: `feat(capacitor-mediapipe): scaffold package`

### Task 44: Android plugin skeleton + lifecycle

Same pattern as Task 20 + Task 29 — Plugin.kt with skeleton methods, PluginState wiring start/stop to HttpServer + handlers. Reuse HandlerDispatch.kt pattern (copy from capacitor-llama for now).

- [ ] Write skeleton, smoke test, commit

### Task 45: Real `MediaPipeHandlers` implementation — TDD

```kotlin
package co.deepvoiceai.dvaibridge.mediapipe

import android.content.Context
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

class MediaPipeHandlers(
    private val context: Context,
    private val modelPath: String,
) : DvaiHandlers {
    private val inference: LlmInference by lazy {
        LlmInference.createFromOptions(
            context,
            LlmInference.LlmInferenceOptions.builder()
                .setModelPath(modelPath)
                .setMaxTokens(2048)
                .build()
        )
    }

    override suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse {
        val messages = body["messages"]?.jsonArray ?: JsonArray(emptyList())
        val prompt = openAIMessagesToPrompt(messages)
        val isStream = body["stream"]?.jsonPrimitive?.boolean ?: false

        return if (isStream) {
            HandlerResponse.Sse(streamMediaPipeResponse(prompt, ctx.modelId))
        } else {
            val text = withContext(Dispatchers.IO) { inference.generateResponse(prompt) }
            HandlerResponse.Json(200, openAIChatCompletionResponse(text, ctx.modelId))
        }
    }

    override suspend fun handleCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse {
        val prompt = body["prompt"]?.jsonPrimitive?.contentOrNull ?: ""
        val chatBody = buildJsonObject {
            put("messages", JsonArray(listOf(buildJsonObject {
                put("role", "user")
                put("content", prompt)
            })))
            for ((k, v) in body) {
                if (k != "prompt" && k != "messages") put(k, v)
            }
        }
        return handleChatCompletion(chatBody, ctx)
    }

    override suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(400, buildJsonObject {
            put("error", "Embeddings not supported on MediaPipe LLM. Use capacitorBackend: \"llama\".")
        })

    override suspend fun handleModels(ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(200, buildJsonObject {
            put("object", "list")
            putJsonArray("data") {
                addJsonObject {
                    put("id", ctx.modelId)
                    put("object", "model")
                    put("owned_by", "mediapipe")
                }
            }
        })

    private fun streamMediaPipeResponse(prompt: String, modelId: String): Flow<String> = callbackFlow {
        val session = LlmInferenceSession.createFromOptions(
            inference,
            LlmInferenceSession.LlmInferenceSessionOptions.builder().build()
        )
        session.addQueryChunk(prompt)
        session.generateResponseAsync { partial, done ->
            val chunk = buildJsonObject {
                put("id", "chatcmpl-mp")
                put("object", "chat.completion.chunk")
                put("created", System.currentTimeMillis() / 1000)
                put("model", modelId)
                putJsonArray("choices") {
                    addJsonObject {
                        put("index", 0)
                        putJsonObject("delta") { put("content", partial) }
                        put("finish_reason", if (done) JsonPrimitive("stop") else JsonNull)
                    }
                }
            }
            trySend("data: $chunk\n\n")
            if (done) {
                trySend("data: [DONE]\n\n")
                close()
            }
        }
        awaitClose { session.close() }
    }

    private fun openAIMessagesToPrompt(messages: JsonArray): String {
        return messages.mapNotNull { msg ->
            val role = msg.jsonObject["role"]?.jsonPrimitive?.contentOrNull ?: "user"
            val content = msg.jsonObject["content"]
            when (content) {
                is JsonPrimitive -> "$role: ${content.content}"
                is JsonArray -> {
                    val texts = content.mapNotNull { part ->
                        if (part.jsonObject["type"]?.jsonPrimitive?.content == "text")
                            part.jsonObject["text"]?.jsonPrimitive?.contentOrNull
                        else null
                    }
                    if (texts.isNotEmpty()) "$role: ${texts.joinToString(" ")}" else null
                }
                else -> null
            }
        }.joinToString("\n")
    }

    private fun openAIChatCompletionResponse(text: String, modelId: String): JsonObject =
        buildJsonObject {
            put("id", "chatcmpl-mp")
            put("object", "chat.completion")
            put("created", System.currentTimeMillis() / 1000)
            put("model", modelId)
            putJsonArray("choices") {
                addJsonObject {
                    put("index", 0)
                    putJsonObject("message") {
                        put("role", "assistant")
                        put("content", text)
                    }
                    put("finish_reason", "stop")
                }
            }
            putJsonObject("usage") {
                put("prompt_tokens", 0)
                put("completion_tokens", 0)
                put("total_tokens", 0)
            }
        }
}
```

- [ ] Tests against fixtures with mocked LlmInference
- [ ] Commit: `feat(capacitor-mediapipe): MediaPipeHandlers implementation`

### Task 46: Vision support for vision-capable Gemma tasks

If a content part is `image_url`, decode → MPImage → addImage to session. Add tests with image fixture.

- [ ] Implement, test, commit

### Task 47: iOS stub plugin

- [ ] Create iOS Plugin.swift that returns clear error: "MediaPipe LLM is Android-only"
- [ ] Smoke test passes (just instantiation)
- [ ] Commit

### Task 48: Lifecycle wiring + plugin registration

Same pattern as Task 29.

- [ ] Wire start/stop, run tests, commit

### Task 49: Phase 1F milestone

- [ ] Android tests pass
- [ ] Pack readiness verified
- [ ] Commit cleanup

---

## Phase 1G — Documentation, CI, final verification (Tasks 50-56)

### Task 50: Write `docs/guide/quickstart-capacitor.md`

Full setup guide: install both core + capacitor + capacitor-llama; cap sync; first-run code; downloadModel example; common errors. ~1500 words.

- [ ] Write doc, build VitePress, commit

### Task 51: Rewrite `docs/guide/native-backend.md`

Replace old `llama-cpp-capacitor` content with new Capacitor-plugin-based content. Cross-reference quickstart-capacitor.md.

- [ ] Rewrite, commit

### Task 52: Write `docs/guide/model-distribution.md`

Per spec §9.4: hosting options, sha256 computation, first-run UX patterns, multi-file models, gated repos, disk-space pre-checks. ~2000 words.

- [ ] Write doc, commit

### Task 53: Write `docs/guide/multimodal.md`

Content-parts format, per-backend support matrix, error semantics, audio decoder format support per platform. ~1500 words.

- [ ] Write doc, commit

### Task 54: Write `docs/guide/tested-models.md` + `docs/development/testing.md` + `docs/development/handler-parity.md` + `docs/development/mac-remote-builds.md`

Four short docs per spec §11 / §12. Each ~500-1000 words. The mac-remote-builds doc uses placeholder values; never references real Mac details.

- [ ] Write all four, commit

### Task 55: GitHub Actions CI workflows

Per spec §11.4 / §11.6 / §11.7:

- `.github/workflows/test-typescript.yml` — already exists; verify still works
- `.github/workflows/test-ios-llama.yml` — runs `xcodebuild test` on `[self-hosted, macOS, ARM64]`, conditional on path filters
- `.github/workflows/test-ios-foundation.yml` — same pattern
- `.github/workflows/test-android-llama-jvm.yml` — runs `./gradlew test` on ubuntu, conditional
- `.github/workflows/test-android-mediapipe-jvm.yml` — same
- `.github/workflows/test-android-instrumented.yml` — runs emulator tests, conditional on audio-decoder paths
- `.github/workflows/fixtures-lint.yml` — quick JSON shape check
- `.github/workflows/smoke-real-models.yml` — nightly + workflow_dispatch

Each workflow uses generic `[self-hosted, macOS, ARM64]` labels — no machine identifiers.

- [ ] Write all workflow YAML, commit
- [ ] User registers self-hosted runner on Mac via GitHub UI

### Task 56: Phase 1G milestone — final verification

- [ ] **Step 1: Full TS suite** — `pnpm test -- --run` → all pass
- [ ] **Step 2: All package builds** — `pnpm -r run build` → all clean
- [ ] **Step 3: VitePress docs build** — `pnpm --filter dvai-bridge-docs docs:build` → success
- [ ] **Step 4: All tarball contents verified** — `pnpm pack --dry-run` per package
- [ ] **Step 5: iOS XCTest full suite (both plugins) via Mac**
- [ ] **Step 6: Android Gradle full suite (both plugins)**
- [ ] **Step 7: Verify no Mac-identifiers committed** — grep repo for `zer0-mac`, `192.168.0.177`, `/Users/zer0/`. All zero hits.
- [ ] **Step 8: Final commit summarizing Phase 1**

```bash
git add -A
git commit -m "chore(phase1): final verification — all green"
```

- [ ] **Step 9: Mark Phase 1 complete in CHANGELOG.md** (entry added per release-versioning convention chosen later)

---

## Self-review notes (covers entire plan, Parts 1 + 2)

**Spec coverage check:**

| Spec section | Tasks |
|---|---|
| §1 Goals — first-party plugins | Tasks 18-49 |
| §1 Goals — embedded HTTP server | Tasks 25-26, 28-29 |
| §1 Goals — native handlers | Tasks 27, 36, 40, 45 |
| §1 Goals — multimodal pass-through | Tasks 33-35, 46 |
| §1 Goals — shed llama-cpp-capacitor | Task 17 |
| §1 Goals — downloadModel helper | Task 32 |
| §1 Goals — self-hosted runner | Task 55 + Mac SSH setup (already done) |
| §3 Architecture | Tasks 13-17, 18+ |
| §4 Repository / packages | Tasks 6, 18, 38, 43 |
| §5 JS shim | Tasks 6-12 |
| §6 Core integration | Tasks 13-17 |
| §7 Native plugin internals | Tasks 18-49 |
| §8 Multimodal | Tasks 33-35, 46 |
| §9 Model distribution | Task 32 |
| §10 Operational concerns (NSC, ATS, memory) | Tasks 20 (NSC manifest), 28-29 (lifecycle) |
| §11.5 Active dev testing | Embedded in every native task — "run the tests" steps |
| §11 CI workflows | Task 55 |
| §12 Documentation | Tasks 50-54 |

**Placeholder scan:**
- Tasks 33-35 are described at high-level rather than full code blocks because the patterns are similar across the three platforms and the AVAudioFile / MediaCodec / image decoder code is straightforward enough that the implementer benefits more from "use these APIs to do X" than from a 200-line scaffold. Acceptable per spec — patterns are constrained, choices are documented.
- Tasks 32, 36 are similarly described. The implementer follows fixture-driven TDD; the test outputs constrain the implementation tightly.
- Task 55 (CI workflows) is described as a list of files rather than each YAML block. Each workflow is small (~30 lines) and follows a known pattern. Acceptable.

**Type consistency:**
- `HandlerContext`, `HandlerResponse`, `DVAIHandlers` — defined in Task 19 (iOS), Task 29 (Android). Used consistently in Tasks 27, 36, 40, 45.
- `LlamaCppBridge` — Swift class declared in Task 23, real impl in Task 30. Kotlin class declared in Task 24, real impl in Task 31.
- `PluginState` — declared + wired in Tasks 28-29.
- `ContentPartsTranslator` — Task 35.
- `AudioDecoder` / `ImageDecoder` — Tasks 33-34.

**Worktree note:**
The plan starts in `feat/phase1-capacitor` worktree (Task 1). Subagent-driven dev using superpowers will use this worktree throughout.
