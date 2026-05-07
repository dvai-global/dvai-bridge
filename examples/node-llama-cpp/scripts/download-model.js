/**
 * Downloads the GGUF model for the node-llama-cpp example if it is not
 * already cached locally. Idempotent — re-running is a no-op.
 *
 * Model: bartowski/Llama-3.2-1B-Instruct-GGUF, Q4_K_M variant (~800 MB).
 *
 * Stored under examples/node-llama-cpp/models/ (gitignored).
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import https from "node:https";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT = path.resolve(__dirname, "..");
const MODELS_DIR = path.join(ROOT, "models");
const MODEL_FILE = "Llama-3.2-1B-Instruct-Q4_K_M.gguf";
const MODEL_URL = `https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/${MODEL_FILE}`;
const MODEL_PATH = path.join(MODELS_DIR, MODEL_FILE);

export function getModelPath() {
	return MODEL_PATH;
}

function downloadOnce(url, destPath) {
	return new Promise((resolve, reject) => {
		const tmp = `${destPath}.partial`;
		const out = fs.createWriteStream(tmp);
		const req = https.get(url, (res) => {
			if (res.statusCode === 301 || res.statusCode === 302) {
				out.close();
				fs.rmSync(tmp, { force: true });
				return downloadOnce(res.headers.location, destPath).then(
					resolve,
					reject,
				);
			}
			if (res.statusCode !== 200) {
				out.close();
				fs.rmSync(tmp, { force: true });
				return reject(
					new Error(`HTTP ${res.statusCode} fetching ${url}`),
				);
			}
			const total = parseInt(res.headers["content-length"] || "0", 10);
			let received = 0;
			let lastTick = Date.now();
			res.on("data", (chunk) => {
				received += chunk.length;
				const now = Date.now();
				if (now - lastTick > 1000) {
					lastTick = now;
					if (total) {
						const pct = ((received / total) * 100).toFixed(1);
						process.stderr.write(
							`  downloading: ${pct}% (${(received / 1e6).toFixed(1)}/${(total / 1e6).toFixed(1)} MB)\r`,
						);
					}
				}
			});
			res.pipe(out);
			out.on("finish", () => {
				out.close();
				fs.renameSync(tmp, destPath);
				process.stderr.write("\n");
				resolve();
			});
		});
		req.on("error", (err) => {
			out.close();
			fs.rmSync(tmp, { force: true });
			reject(err);
		});
	});
}

export async function ensureModel() {
	if (!fs.existsSync(MODELS_DIR)) {
		fs.mkdirSync(MODELS_DIR, { recursive: true });
	}
	if (fs.existsSync(MODEL_PATH)) {
		const sz = fs.statSync(MODEL_PATH).size;
		if (sz > 100 * 1024 * 1024) {
			// > 100 MB → assume valid (the real file is ~800 MB).
			return MODEL_PATH;
		}
		console.warn(
			`[download-model] cached file ${MODEL_PATH} looks too small (${sz}B); refetching.`,
		);
		fs.rmSync(MODEL_PATH);
	}
	console.log(`[download-model] fetching ${MODEL_URL}`);
	console.log(`[download-model]    -> ${MODEL_PATH}`);
	await downloadOnce(MODEL_URL, MODEL_PATH);
	console.log(`[download-model] done.`);
	return MODEL_PATH;
}

// CLI entry: `node scripts/download-model.js`
if (process.argv[1] === __filename) {
	ensureModel().then(
		() => process.exit(0),
		(err) => {
			console.error(err);
			process.exit(1);
		},
	);
}
