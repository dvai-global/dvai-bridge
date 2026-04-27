package co.deepvoiceai.bridge

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProgressBroadcasterTest {
    @Test
    fun `flow and listener both receive emitted events`() = runTest {
        val b = ProgressBroadcaster()
        val captured = mutableListOf<ProgressEvent>()
        b.addListener { captured.add(it) }

        // Emit before any flow subscriber — the SharedFlow's replay buffer
        // should make the most-recent event visible to a late subscriber.
        b.emit(ProgressEvent.Started("phase-1"))

        val replayed = b.flow.first()
        assertTrue("late subscriber should see replay", replayed is ProgressEvent.Started)

        b.emit(ProgressEvent.Progress("phase-1", percent = 0.5f, message = "halfway"))
        b.emit(ProgressEvent.Completed("phase-1"))

        // Listener saw all 3 events synchronously on the emit thread.
        assertEquals(3, captured.size)
        assertTrue(captured[0] is ProgressEvent.Started)
        assertTrue(captured[1] is ProgressEvent.Progress)
        assertTrue(captured[2] is ProgressEvent.Completed)
    }

    @Test
    fun `removed listener stops receiving events`() {
        val b = ProgressBroadcaster()
        val captured = mutableListOf<ProgressEvent>()
        val listener = ProgressListener { captured.add(it) }
        b.addListener(listener)
        b.emit(ProgressEvent.Started("p"))
        b.removeListener(listener)
        b.emit(ProgressEvent.Completed("p"))
        assertEquals(1, captured.size)
    }

    @Test
    fun `listener exception does not block other listeners`() {
        val b = ProgressBroadcaster()
        val good = mutableListOf<ProgressEvent>()
        b.addListener { throw RuntimeException("misbehaving listener") }
        b.addListener { good.add(it) }
        b.emit(ProgressEvent.Started("p"))
        assertEquals(1, good.size)
    }
}
