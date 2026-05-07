package co.deepvoiceai.example.litert

import android.os.Bundle
import android.os.Environment
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import co.deepvoiceai.bridge.BackendKind
import co.deepvoiceai.bridge.DVAIBridge
import co.deepvoiceai.bridge.StartOptions
import com.aallam.openai.api.chat.ChatCompletionChunk
import com.aallam.openai.api.chat.ChatCompletionRequest
import com.aallam.openai.api.chat.ChatMessage
import com.aallam.openai.api.chat.ChatRole
import com.aallam.openai.api.model.ModelId
import com.aallam.openai.client.OpenAI
import com.aallam.openai.client.OpenAIHost
import kotlinx.coroutines.launch
import java.io.File

/**
 * Phase 2 Task 3 — minimal Compose app for the **LiteRT** backend.
 *
 * LiteRT is Google's TFLite-successor runtime. The DVAI SDK exposes it
 * for Llama-style stateful `.tflite` (and `.litertlm`) checkpoints
 * driven through bare `CompiledModel` calls. The reference asset is
 * `litert-community/Llama-3.2-1B-Instruct` Q4 from HuggingFace.
 *
 * NOTE: LiteRT requires a `tokenizer.json` alongside the model — the
 * SDK ships a pure-Kotlin BPE parser; SentencePiece / Unigram tokenizers
 * are not supported (Gemma users should pick MediaPipe instead).
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        DVAIBridge.init(this)

        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    LiteRTScreen()
                }
            }
        }
    }
}

private const val MODEL_FILENAME = "Llama-3.2-1B-Instruct.tflite"
private const val TOKENIZER_FILENAME = "tokenizer.json"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LiteRTScreen() {
    val scope = rememberCoroutineScope()
    var response by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("Idle. Tap Load + Ask to begin.") }
    var busy by remember { mutableStateOf(false) }

    val isReady by DVAIBridge.reactive.isReady.collectAsState()
    val baseUrl by DVAIBridge.reactive.baseUrl.collectAsState()
    val modelId by DVAIBridge.reactive.modelId.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("DVAI · LiteRT backend") })
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
            Text(
                text = if (isReady) "Server: $baseUrl  ($modelId)" else "Server: not started",
                style = MaterialTheme.typography.bodyMedium,
            )

            Button(
                enabled = !busy,
                onClick = {
                    scope.launch {
                        busy = true
                        try {
                            status = "Starting LiteRT backend…"
                            val modelPath = expectedModelPath()
                            val tokenizerDir = expectedTokenizerDir()
                            if (!modelPath.exists()) {
                                status = "Model file missing at ${modelPath.path}\n" +
                                    "Push it via: adb push Llama-3.2-1B-Instruct.tflite /sdcard/Download/"
                                return@launch
                            }
                            if (!File(tokenizerDir, TOKENIZER_FILENAME).exists()) {
                                status = "tokenizer.json missing at ${tokenizerDir.path}\n" +
                                    "Push it via: adb push tokenizer.json /sdcard/Download/litert-tokenizer/"
                                return@launch
                            }
                            val state = DVAIBridge.start(
                                StartOptions(
                                    backend = BackendKind.LiteRT,
                                    modelPath = modelPath.absolutePath,
                                    tokenizerPath = tokenizerDir.absolutePath,
                                    contextSize = 2048,
                                    maxNewTokens = 128,
                                ),
                            )
                            status = "Server up at ${state.baseUrl}. Streaming prompt…"

                            response = ""
                            val openai = OpenAI(
                                host = OpenAIHost(baseUrl = state.baseUrl + "/"),
                                token = "ignored",
                            )
                            openai.chatCompletions(
                                ChatCompletionRequest(
                                    model = ModelId(state.modelId),
                                    messages = listOf(
                                        ChatMessage(role = ChatRole.User, content = "Tell me a joke."),
                                    ),
                                ),
                            ).collect { chunk: ChatCompletionChunk ->
                                val delta = chunk.choices.firstOrNull()?.delta?.content.orEmpty()
                                if (delta.isNotEmpty()) {
                                    response += delta
                                }
                            }
                            status = "Stream complete."
                        } catch (t: Throwable) {
                            status = "Error: ${t.message ?: t::class.simpleName}"
                        } finally {
                            busy = false
                        }
                    }
                },
            ) {
                Text(if (busy) "Working…" else "Load + Ask")
            }

            if (busy) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth(1f))
            }

            Spacer(modifier = Modifier.height(8.dp))
            Text(text = status, style = MaterialTheme.typography.bodySmall)

            Spacer(modifier = Modifier.height(8.dp))
            Text(text = "Response:", style = MaterialTheme.typography.titleMedium)
            Text(text = response.ifEmpty { "(no tokens yet)" })
        }
    }
}

private fun expectedModelPath(): File =
    File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        MODEL_FILENAME,
    )

private fun expectedTokenizerDir(): File =
    File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
        "litert-tokenizer",
    )
