package co.deepvoiceai.example.llama

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import co.deepvoiceai.bridge.DVAIBridge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Phase 4 v3.1 E2E test — Android → DVAI Hub over LAN.
 *
 * Uses raw OkHttp (no openai-kotlin client) to POST JSON directly to
 * the Hub's `/v1/chat/completions` endpoint. Three buttons:
 *
 *   • Test Local       → request "Llama-3.2-1B-Instruct" → Hub serves
 *                        via its built-in backend.
 *   • Test Ollama      → request "qwen2.5-coder:1.5b"    → Hub routes
 *                        through engine-bridge to Ollama.
 *   • Test Refuse      → request fictional model         → Hub returns
 *                        503 with structured error.
 *
 * Each request goes out as plain HTTP (no v3.1 identity headers), so
 * Hub logs the audit row under appId="anonymous" (backwards-compat
 * path).
 *
 * v3.2 — "Probe device hardware" button calls the SDK-side
 * `DVAIBridge.assessHardware()` to demo the pre-init capability gate
 * without needing to actually start a model.
 *
 * v3.2.1 — distributed-inference pattern. The full SDK-routed
 * offload flow (precheck → if `.ok`, run llama.cpp locally; if
 * `.offloadOnly`, route through paired Hub via OffloadProxy with
 * HMAC-signed identity headers; if `.tooWeak`, surface error) is
 * shipped on Android via `co.deepvoiceai.bridge.DVAIBridge.start(...)`
 * + `OffloadConfig(enabled = true, ...)` + `initiatePairing(peer)`.
 * The reference implementation lives in
 * `examples/ios-offload-dogfood` (Swift); the same SDK shape exists
 * verbatim in Kotlin. This example deliberately uses raw-HTTP-to-Hub
 * to demonstrate the simpler "always offload" path used by Android
 * UIs that don't want to host the local llama.cpp backend at all.
 * For the local-OR-offload routing pattern, see the iOS dogfood.
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // v3.2 — DVAIBridge.assessHardware() needs the application
        // context for ActivityManager-backed RAM detection.
        DVAIBridge.init(applicationContext)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    HubE2EScreen()
                }
            }
        }
    }
}

private const val HUB_BASE_URL = "http://192.168.0.195:38883"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HubE2EScreen() {
    val scope = rememberCoroutineScope()
    var response by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("Idle. Tap a test button.") }
    var busy by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("DVAI Hub · Android E2E") })
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(text = "Hub: $HUB_BASE_URL", style = MaterialTheme.typography.bodyMedium)

            Button(
                enabled = !busy,
                onClick = {
                    scope.launch {
                        runRequest(
                            modelId = "Llama-3.2-1B-Instruct",
                            prompt = "Reply with: HELLO",
                            label = "Test Local (Hub Llama-3.2-1B)",
                            onStatus = { status = it },
                            onResponse = { response = it },
                            onBusy = { busy = it },
                        )
                    }
                },
            ) { Text(if (busy) "Working…" else "Test Local (Hub Llama-3.2-1B)") }

            Button(
                enabled = !busy,
                onClick = {
                    scope.launch {
                        runRequest(
                            modelId = "qwen2.5-coder:1.5b",
                            prompt = "Output only: 7+1=",
                            label = "Test Ollama (Hub → engine-bridge)",
                            onStatus = { status = it },
                            onResponse = { response = it },
                            onBusy = { busy = it },
                        )
                    }
                },
            ) { Text(if (busy) "Working…" else "Test Ollama (Hub → engine-bridge)") }

            Button(
                enabled = !busy,
                onClick = {
                    scope.launch {
                        runRequest(
                            modelId = "completely-fictional-model",
                            prompt = "hi",
                            label = "Test refuse (no matching backend)",
                            onStatus = { status = it },
                            onResponse = { response = it },
                            onBusy = { busy = it },
                        )
                    }
                },
            ) { Text(if (busy) "Working…" else "Test Refuse (no matching backend)") }

            // v3.2 — pre-init hardware assessment demo.
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = "v3.2 — pre-init hardware assessment",
                style = MaterialTheme.typography.titleMedium,
            )
            Button(
                enabled = !busy,
                onClick = {
                    busy = true
                    status = "Running DVAIBridge.assessHardware()…"
                    response = ""
                    try {
                        val a = DVAIBridge.assessHardware(
                            hardwareMinimum = 3.0,
                            minLocalCapability = 10.0,
                        )
                        response = buildString {
                            append("mode: ").append(a.mode).append('\n')
                            append("tokPerSec: ").append(a.tokPerSec).append('\n')
                            append("hints: hasNpu=").append(a.hints.hasNpu)
                            append(", ramGb=").append(a.hints.ramGb)
                            append(", gpu=").append(a.hints.gpuClass)
                            append(", cpu=").append(a.hints.cpuClass).append('\n')
                            append("reason: ").append(a.reason)
                        }
                        status = "Done. Mode: ${a.mode}"
                    } catch (e: Throwable) {
                        status = "assessHardware() threw: ${e.message}"
                    } finally {
                        busy = false
                    }
                },
            ) { Text(if (busy) "Working…" else "Probe device hardware (assessHardware)") }

            if (busy) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth(1f))
            }

            Spacer(modifier = Modifier.height(8.dp))
            Text(text = status, style = MaterialTheme.typography.bodySmall)

            Spacer(modifier = Modifier.height(8.dp))
            Text(text = "Response:", style = MaterialTheme.typography.titleMedium)
            Text(text = response.ifEmpty { "(no response yet)" })
        }
    }
}

private val httpClient: OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(120, TimeUnit.SECONDS)
    .writeTimeout(15, TimeUnit.SECONDS)
    .build()

private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

private suspend fun runRequest(
    modelId: String,
    prompt: String,
    label: String,
    onStatus: (String) -> Unit,
    onResponse: (String) -> Unit,
    onBusy: (Boolean) -> Unit,
) {
    onBusy(true)
    onResponse("")
    onStatus("$label\nPOSTing $HUB_BASE_URL/v1/chat/completions ($modelId)…")
    try {
        val payload = JSONObject().apply {
            put("model", modelId)
            put("messages", JSONArray().apply {
                put(JSONObject().apply {
                    put("role", "user")
                    put("content", prompt)
                })
            })
            put("max_tokens", 30)
            put("stream", false)
        }.toString()
        val request = Request.Builder()
            .url("$HUB_BASE_URL/v1/chat/completions")
            .post(payload.toRequestBody(jsonMediaType))
            .build()
        val (status, body) = withContext(Dispatchers.IO) {
            httpClient.newCall(request).execute().use { res ->
                Pair(res.code, res.body?.string().orEmpty())
            }
        }
        if (status == 200) {
            // Pull the assistant content out of the OpenAI response shape
            val parsed = JSONObject(body)
            val content = parsed.optJSONArray("choices")
                ?.optJSONObject(0)
                ?.optJSONObject("message")
                ?.optString("content")
                .orEmpty()
            onResponse(content.ifEmpty { body.take(400) })
            onStatus("$label\n✓ HTTP $status")
        } else {
            // Show the structured error
            onResponse(body.take(600))
            onStatus("$label\n✗ HTTP $status")
        }
    } catch (t: Throwable) {
        onStatus("$label\n✗ Error: ${t.message ?: t::class.simpleName}")
    } finally {
        onBusy(false)
    }
}
