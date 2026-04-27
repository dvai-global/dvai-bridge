package co.deepvoiceai.bridge

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Compose- / Lifecycle-friendly reactive view of the running bridge state.
 * Mirrors iOS `DVAIBridgeReactiveState` (which uses `@Observable` /
 * `ObservableObject`).
 *
 * Each property is a [StateFlow] you can `collect` from in a Compose
 * `LaunchedEffect` or wire to a ViewModel:
 *
 * ```kotlin
 * @Composable
 * fun BridgeStatus() {
 *     val isReady by DVAIBridge.reactive.isReady.collectAsState()
 *     val baseUrl by DVAIBridge.reactive.baseUrl.collectAsState()
 *     Text(if (isReady) "Ready: $baseUrl" else "Not running")
 * }
 * ```
 *
 * The state is updated internally on every successful [DVAIBridge.start] and
 * [DVAIBridge.stop]; consumers never write directly.
 */
class DVAIBridgeReactiveState internal constructor() {
    private val _isReady = MutableStateFlow(false)
    val isReady: StateFlow<Boolean> = _isReady.asStateFlow()

    private val _baseUrl = MutableStateFlow<String?>(null)
    val baseUrl: StateFlow<String?> = _baseUrl.asStateFlow()

    private val _port = MutableStateFlow<Int?>(null)
    val port: StateFlow<Int?> = _port.asStateFlow()

    private val _backend = MutableStateFlow<BackendKind?>(null)
    val backend: StateFlow<BackendKind?> = _backend.asStateFlow()

    private val _modelId = MutableStateFlow<String?>(null)
    val modelId: StateFlow<String?> = _modelId.asStateFlow()

    /** Internal setter, invoked by [DVAIBridge] on start. */
    internal fun onStarted(server: BoundServer) {
        _baseUrl.value = server.baseUrl
        _port.value = server.port
        _backend.value = server.backend
        _modelId.value = server.modelId
        _isReady.value = true
    }

    /** Internal setter, invoked by [DVAIBridge] on stop. */
    internal fun onStopped() {
        _isReady.value = false
        _baseUrl.value = null
        _port.value = null
        _backend.value = null
        _modelId.value = null
    }
}
