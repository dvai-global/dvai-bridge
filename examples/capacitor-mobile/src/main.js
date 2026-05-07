// Capacitor + @dvai-bridge/capacitor — minimum viable hybrid app.
//
// Flow:
//   1. User enters the on-device model path (or relies on the placeholder).
//   2. Tap "Start" -> DVAIBridge.start({ backend: 'llama', modelPath })
//      boots the native llama.cpp engine and the embedded HTTP server.
//      `start()` resolves with `{ baseUrl, port, backend, modelId }`.
//   3. Tap "Send" -> POST a streaming chat completion to `${baseUrl}/chat/completions`.
//      Every SSE line is decoded inline and appended to the response textarea.
//   4. Tap "Stop" -> DVAIBridge.stop() releases the model and server.
//
// The build step (scripts/build-www.mjs) bundles `@dvai-bridge/capacitor`
// + the @capacitor/core init shim into `www/` via esbuild.

import { DVAIBridge } from "@dvai-bridge/capacitor";

const $ = (id) => document.getElementById(id);
const statusEl = $("status");
const modelPathInput = $("modelPath");
const promptInput = $("prompt");
const outputEl = $("output");
const startBtn = $("start");
const stopBtn = $("stop");
const sendBtn = $("send");

let server = null;

function setStatus(text, kind = "info") {
  statusEl.textContent = text;
  statusEl.className = `status ${kind === "info" ? "" : kind}`.trim();
}

startBtn.addEventListener("click", async () => {
  const modelPath = modelPathInput.value.trim() || modelPathInput.placeholder;
  setStatus(`Loading model from ${modelPath}…`);
  startBtn.disabled = true;
  try {
    const sub = await DVAIBridge.addProgressListener((e) => {
      if (e.percent != null) {
        setStatus(`${e.phase}: ${Math.round(e.percent)}%`);
      } else if (e.message) {
        setStatus(`${e.phase}: ${e.message}`);
      } else {
        setStatus(`${e.phase}…`);
      }
    });
    server = await DVAIBridge.start({
      backend: "llama",
      modelPath,
      contextSize: 2048,
      gpuLayers: 99,
    });
    await sub.remove();
    setStatus(`Ready: ${server.baseUrl} (${server.modelId})`, "ok");
    sendBtn.disabled = false;
    stopBtn.disabled = false;
  } catch (err) {
    setStatus(`Failed: ${err?.message ?? err}`, "error");
    startBtn.disabled = false;
  }
});

stopBtn.addEventListener("click", async () => {
  try {
    await DVAIBridge.stop();
    server = null;
    sendBtn.disabled = true;
    stopBtn.disabled = true;
    startBtn.disabled = false;
    setStatus("Stopped.");
  } catch (err) {
    setStatus(`Stop failed: ${err?.message ?? err}`, "error");
  }
});

sendBtn.addEventListener("click", async () => {
  if (!server) {
    setStatus("Start the server first.", "error");
    return;
  }
  const prompt = promptInput.value.trim();
  if (!prompt) {
    return;
  }
  outputEl.value = "";
  sendBtn.disabled = true;
  setStatus("Streaming…");
  try {
    const res = await fetch(`${server.baseUrl}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: server.modelId,
        messages: [{ role: "user", content: prompt }],
        stream: true,
      }),
    });
    if (!res.ok || !res.body) {
      throw new Error(`HTTP ${res.status}`);
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let idx;
      while ((idx = buf.indexOf("\n\n")) !== -1) {
        const event = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        for (const line of event.split("\n")) {
          if (!line.startsWith("data:")) continue;
          const payload = line.slice(5).trim();
          if (payload === "[DONE]") {
            setStatus("Done.", "ok");
            sendBtn.disabled = false;
            return;
          }
          try {
            const json = JSON.parse(payload);
            const piece = json.choices?.[0]?.delta?.content ?? "";
            if (piece) outputEl.value += piece;
          } catch {
            // Ignore non-JSON keepalives.
          }
        }
      }
    }
    setStatus("Done.", "ok");
  } catch (err) {
    setStatus(`Stream failed: ${err?.message ?? err}`, "error");
  } finally {
    sendBtn.disabled = false;
  }
});
