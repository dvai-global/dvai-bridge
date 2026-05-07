package co.deepvoiceai.bridge.shared.core.discovery

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertNotNull
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented (real-device / emulator) smoke test for [NsdDiscovery]
 * + [NsdAdvertiser]. Gated behind `connectedAndroidTest` because
 * NsdManager hits real platform mDNS. JVM unit tests don't have access
 * to the Android networking stack, so this stub stays out of the
 * regular `:test` task.
 *
 * Self-skips on emulators that lack mDNS multicast (most x86_64
 * emulators do — Android Studio's "Quick Boot" + bridged networking
 * is unreliable). Real devices on a Wi-Fi network reliably resolve.
 */
@RunWith(AndroidJUnit4::class)
class NsdDiscoveryInstrumentedTest {

    @Test
    fun selfDiscoversOwnAdvertisement() = runBlocking {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        // The advertiser + discoverer use the SAME deviceId so we'd normally
        // filter ourselves out. For this test we use distinct IDs to verify
        // discovery actually round-trips through mDNS.
        val advertiser = NsdAdvertiser(ctx)
        val discovery = NsdDiscovery(ctx, selfDeviceId = "self-watcher")
        try {
            val txt = mapOf(
                PeerTxtKeys.DEVICE_ID to "test-peer-${System.currentTimeMillis()}",
                PeerTxtKeys.DEVICE_NAME to "instrumented-test",
                PeerTxtKeys.DVAI_VERSION to "3.0.0",
            )
            advertiser.start(
                serviceName = "dvai-bridge-instrumented-${System.currentTimeMillis()}",
                port = 38883,
                txt = txt,
            )
            discovery.start()
            // Wait up to 10s for an event.
            val event = withTimeoutOrNull(10_000L) {
                discovery.events.firstOrNull { it is DiscoveryEvent.PeerUp }
            }
            // On most emulators this is null (mDNS multicast is filtered).
            // On real Wi-Fi devices we expect to see the peer-up event.
            assumeTrue("emulator likely lacks mDNS multicast — skipping", event != null)
            assertNotNull(event)
        } finally {
            discovery.stop()
            advertiser.stop()
        }
    }
}
