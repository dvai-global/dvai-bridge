package co.deepvoiceai.bridge

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Internal: routes [ProgressEvent]s to both subscribers of the [SharedFlow]
 * surface (idiomatic Kotlin) and registered [ProgressListener] callbacks
 * (Java-friendly + parity with the iOS Combine + AsyncStream surfaces).
 *
 * Both surfaces emit the same events in the same order. Listener callbacks
 * are invoked synchronously on the same thread that called [emit] —
 * consumers should hand off to their own dispatcher if they want to update
 * UI from a UI thread.
 */
internal class ProgressBroadcaster {
    // Replay buffer of 1 so a late subscriber sees the most recent event.
    // extraBufferCapacity = 16 absorbs short bursts without suspending the
    // emit() caller.
    private val sharedFlow = MutableSharedFlow<ProgressEvent>(replay = 1, extraBufferCapacity = 16)
    val flow: SharedFlow<ProgressEvent> = sharedFlow.asSharedFlow()

    private val listeners = CopyOnWriteArrayList<ProgressListener>()

    fun addListener(listener: ProgressListener) {
        listeners.add(listener)
    }

    fun removeListener(listener: ProgressListener) {
        listeners.remove(listener)
    }

    /**
     * Emit an event to all subscribers. tryEmit returns false only if the
     * buffer is full; we ignore the failure (event will arrive via the
     * listener path either way).
     */
    fun emit(event: ProgressEvent) {
        sharedFlow.tryEmit(event)
        for (l in listeners) {
            try {
                l.onProgress(event)
            } catch (_: Throwable) {
                // Don't let a misbehaving listener block other listeners.
            }
        }
    }
}

/** SAM interface for [DVAIBridge.addProgressListener] / [DVAIBridge.removeProgressListener]. */
fun interface ProgressListener {
    fun onProgress(event: ProgressEvent)
}
