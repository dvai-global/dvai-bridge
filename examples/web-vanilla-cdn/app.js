/**
 * Vanilla-JS dvai-bridge example. No build step, no bundler.
 *
 * VanillaDVAI is attached to the global scope by the IIFE bundle loaded
 * from index.html. We instantiate it pointing at the smallest tested
 * Transformers.js Gemma model, run one chat completion against the
 * MSW-intercepted local endpoint, and stream the result into the page.
 */

const statusEl = document.getElementById("status");
const dotEl = document.getElementById("status-dot");
const runBtn = document.getElementById("run");
const outputEl = document.getElementById("output");

function setStatus(text, ready = false) {
	statusEl.textContent = text;
	dotEl.classList.toggle("ready", ready);
}

// `VanillaDVAI` is the IIFE bundle's top-level export. The class itself
// is on `.VanillaDVAI`; the legacy assignment to `window.VanillaDVAI` in
// the source overrides this with the class directly when the source's
// last lines run, so we accept either shape.
const Vanilla = window.VanillaDVAI?.VanillaDVAI ?? window.VanillaDVAI;

if (!Vanilla) {
	setStatus("Failed to load @dvai-bridge/vanilla bundle.");
	outputEl.textContent =
		"VanillaDVAI global was not found. Check the <script src=\"...\"> URL.";
	throw new Error("VanillaDVAI not found on window.");
}

setStatus("ready to initialize");
runBtn.disabled = false;

runBtn.addEventListener("click", async () => {
	runBtn.disabled = true;
	outputEl.textContent = "";

	const dvai = new Vanilla({
		backend: "transformers",
		// Smallest tested Gemma model; q4 keeps the download small enough
		// for a CDN demo.
		transformersModelId: "onnx-community/gemma-3n-E2B-it-ONNX",
		dtype: "q4",
		device: "auto",
		// Default: MSW transport in browser; intercepts api.openai.local.
	});

	try {
		dvai.subscribe((s) => {
			if (!s.isReady) {
				setStatus(`loading: ${s.progress || "..."}`);
			} else {
				setStatus(`ready (${s.backend})`, true);
			}
		});

		await dvai.initialize();
		setStatus("ready, running chat completion...", true);

		// Hit the OpenAI-compatible mock endpoint via plain fetch — no SDK
		// required. MSW intercepts api.openai.local and routes to the
		// in-page Transformers.js runtime.
		const res = await fetch(
			"https://api.openai.local/v1/chat/completions",
			{
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					model: dvai.getState().modelId,
					messages: [
						{ role: "system", content: "You are a helpful local AI." },
						{ role: "user", content: "Say hello in one short sentence." },
					],
					max_tokens: 64,
					temperature: 0.2,
				}),
			},
		);

		const json = await res.json();
		const text = json?.choices?.[0]?.message?.content ?? JSON.stringify(json);
		outputEl.textContent = text;
		setStatus("done", true);
	} catch (err) {
		console.error(err);
		setStatus("error");
		outputEl.textContent = err?.message ?? String(err);
	} finally {
		runBtn.disabled = false;
		try {
			await dvai.unload();
		} catch (_) {
			/* ignored */
		}
	}
});
