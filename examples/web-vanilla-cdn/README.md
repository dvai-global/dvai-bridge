# web-vanilla-cdn

Smallest viable dvai-bridge example: a single `index.html` + `app.js`,
no build step, no bundler, no `package.json`. Loads
`@dvai-bridge/vanilla` via a `<script>` tag and runs an OpenAI-compatible
chat completion in-browser against a local Transformers.js model.

## Run

You need any static-file server. From this directory:

```bash
python -m http.server 8000
# or, if you prefer Node:
# npx --yes serve -l 8000 .
```

Then browse to <http://localhost:8000/>. Click **Initialize and run a
chat completion**. The first run downloads
`onnx-community/gemma-3n-E2B-it-ONNX` (q4) to your browser's IndexedDB
HuggingFace cache (~600 MB); subsequent runs hit the cache.

The completion is intercepted by MSW (the default browser transport) at
`https://api.openai.local/v1/chat/completions` and routed to the
in-browser Transformers.js pipeline. The plain `fetch` call in `app.js`
shows that no DVAI-specific client API is needed — any OpenAI-shaped
request body works.

## Where the script tag points

Inside this monorepo the example loads the IIFE bundle directly out of
the workspace build:

```html
<script src="../../packages/dvai-bridge-vanilla/dist/index.global.js"></script>
```

That keeps the example runnable without a public npm publish. When the
package goes public you would swap it for the canonical jsDelivr URL:

```html
<script src="https://cdn.jsdelivr.net/npm/@dvai-bridge/vanilla@latest/dist/index.global.js"></script>
```

Both shapes leave the `app.js` code unchanged — `VanillaDVAI` is on
`window` either way.

## What to look for in the demo recording

1. The page loads without a bundler — view-source confirms a single
   `<script src="...">` tag.
2. The status dot turns green once the model finishes loading.
3. The completion text appears in the `<pre>` block; no extra plumbing.

## Smoke test

```bash
bash smoke.sh
```

`smoke.sh` does **not** launch a browser. It verifies that:

- `index.html` parses,
- the local script reference (`../../packages/dvai-bridge-vanilla/dist/index.global.js`)
  exists on disk in the workspace,
- the documented jsDelivr URL is reachable (200) once the package is
  public — the smoke test treats a 404 as a soft warning so it doesn't
  block local CI.

## Swap the model

Edit `app.js`:

```js
const dvai = new Vanilla({
  backend: "transformers",
  transformersModelId: "Xenova/Llama-3.2-1B-Instruct",
  dtype: "q4",
});
```

Any Transformers.js-compatible text-generation model works. See
<https://huggingface.co/models?library=transformers.js> for the catalog.
