/**
 * Phase 4 — DVAI Hub model name parser.
 *
 * Parses any of the canonical naming conventions in the wild
 * (Gemma, Llama, Phi, Qwen, Mistral; GGUF / MLX / ONNX / MLC / Ollama
 * / raw HuggingFace) into a structured `ModelDescriptor`. The
 * descriptor feeds the SubstitutionPolicy and the EngineBridge —
 * each gets a semantic view of the request rather than a string match.
 *
 * Strategy: tokenize, then look up each token in a controlled
 * vocabulary. Unrecognized fields default to `null` / `"unknown"`,
 * which the substitution policy treats as "refuse to substitute" —
 * failure mode is strictness, not silent wrong-routing.
 */

export interface ModelDescriptor {
  /** Canonical lowercase: "gemma" | "llama" | "phi" | "qwen" | "mistral" | "deepseek" | "yi" | "tinyllama" | "falcon" | "stablelm" | "unknown" */
  family: string;
  /** Numeric version as supplied: "2", "3.2", "4", "3.5". `null` when no recognizable version follows the family token. */
  version: string | null;
  /** Canonical lowercase size: "1b" | "2b" | "3b" | "7b" | "13b" | "34b" | "70b" | "e2b" | "mini" | "medium" | "tiny" | "unknown" */
  size: string;
  /** Canonical lowercase quant id, or `null` when no recognizable quant token. */
  quant: string | null;
  /** Canonical lowercase: "instruct" | "chat" | "code" | "base" | "vision" | "embed" | "unknown" */
  type: string;
  /** Verbatim input. Always preserved so the chosen backend can use the original string for its own model resolution. */
  originalString: string;
}

/* -------------------------------------------------------------------------- */
/* Vocabularies                                                               */
/* -------------------------------------------------------------------------- */

const FAMILY_ALIASES: Record<string, string> = {
  // case-insensitive lookup; we normalize to lowercase first
  "gemma": "gemma",
  "gemma2": "gemma",
  "gemma3": "gemma",
  "gemma3n": "gemma",
  "gemma4": "gemma",

  "llama": "llama",
  "llama2": "llama",
  "llama3": "llama",

  "phi": "phi",
  // NOTE: `phi2`, `phi3` deliberately NOT listed here — letting them fall
  // through to FAMILY_VERSION_RE means the version is captured (phi3 → version=3).
  // (Contrast with qwen2/qwen3 below, which the corpus expects to NOT split version.)

  "qwen": "qwen",
  "qwen2": "qwen",
  "qwen3": "qwen",

  "mistral": "mistral",
  "mixtral": "mixtral",
  "deepseek": "deepseek",
  "yi": "yi",
  "tinyllama": "tinyllama",
  "falcon": "falcon",
  "stablelm": "stablelm",
};

const SIZE_ALIASES: Record<string, string> = {
  "1b": "1b",
  "1.1b": "1b",
  "1.5b": "1b",
  "1.7b": "2b",
  "2b": "2b",
  "3b": "3b",
  "3.8b": "3b",
  "7b": "7b",
  "8b": "7b",
  "13b": "13b",
  "14b": "13b",
  "30b": "30b",
  "34b": "34b",
  "70b": "70b",
  "72b": "70b",
  "405b": "405b",
  // textual sizes (Phi-3, Gemma 3n)
  "tiny": "tiny",
  "mini": "mini",
  "medium": "medium",
  "small": "small",
  "large": "large",
  "e2b": "e2b",
  "e4b": "e4b",
};

const QUANT_ALIASES: Record<string, string> = {
  // GGUF k-quants
  "q2_k": "q2_k",
  "q3_k": "q3_k",
  "q3_k_s": "q3_k_s",
  "q3_k_m": "q3_k_m",
  "q3_k_l": "q3_k_l",
  "q4_0": "q4_0",
  "q4_1": "q4_1",
  "q4_k": "q4_k",
  "q4_k_s": "q4_k_s",
  "q4_k_m": "q4_k_m",
  "q5_0": "q5_0",
  "q5_1": "q5_1",
  "q5_k": "q5_k",
  "q5_k_s": "q5_k_s",
  "q5_k_m": "q5_k_m",
  "q6_k": "q6_k",
  "q8_0": "q8_0",
  // MLC convention: q4f16_1, q4f32_1, q3f16_1
  "q3f16_1": "q3_k_m_approx",
  "q4f16_0": "q4_k_s_approx",
  "q4f16_1": "q4_k_m_approx",
  "q4f32_1": "q4_k_m_approx",
  "q8f16_1": "q8_0",
  // MLX / generic bit-width
  "2bit": "2bit",
  "3bit": "3bit",
  "4bit": "4bit",
  "5bit": "5bit",
  "6bit": "6bit",
  "8bit": "8bit",
  "int4": "4bit",
  "int8": "8bit",
  // float
  "f16": "f16",
  "f32": "f32",
  "fp16": "f16",
  "fp32": "f32",
  "bf16": "bf16",
  // "q4" by itself — common shorthand
  "q4": "q4_k_m",
  "q5": "q5_k_m",
  "q6": "q6_k",
  "q8": "q8_0",
  "q3": "q3_k_m",
  "q2": "q2_k",
};

const TYPE_ALIASES: Record<string, string> = {
  "instruct": "instruct",
  "instruction": "instruct",
  "instructed": "instruct",
  "it": "instruct",
  "chat": "chat",
  "chatml": "chat",
  "code": "code",
  "coder": "code",
  "base": "base",
  "pretrained": "base",
  "pre-trained": "base",
  "vision": "vision",
  "vlm": "vision",
  "multimodal": "vision",
  "embed": "embed",
  "embedding": "embed",
  "embeddings": "embed",
};

/**
 * Quant ordering — higher index = higher quality. Used by the
 * SubstitutionPolicy to compare quant levels.
 */
export const QUANT_ORDER: ReadonlyArray<string> = [
  "q2_k",
  "q3_k_s",
  "q3_k",
  "q3_k_m",
  "q3_k_l",
  "q3_k_m_approx",
  "2bit",
  "3bit",
  "q4_0",
  "q4_1",
  "q4_k_s",
  "q4_k",
  "q4_k_s_approx",
  "q4_k_m",
  "q4_k_m_approx",
  "4bit",
  "q5_0",
  "q5_1",
  "q5_k_s",
  "q5_k",
  "q5_k_m",
  "5bit",
  "q6_k",
  "6bit",
  "q8_0",
  "8bit",
  "bf16",
  "f16",
  "f32",
];

/* -------------------------------------------------------------------------- */
/* Parser                                                                     */
/* -------------------------------------------------------------------------- */

const VERSION_RE = /^v?\d+(?:\.\d+)?$/;
const FAMILY_VERSION_RE = /^([a-z]+)(\d+(?:\.\d+)?)$/;

/**
 * Parse a model name string into a ModelDescriptor.
 *
 * Examples (see hub/tests/ModelParser.test.ts for the full corpus):
 *   - `gemma-4-E2B-q4-instruct` → {family: "gemma", version: "4", size: "e2b", quant: "q4_k_m", type: "instruct"}
 *   - `Llama-3.2-3B-Instruct-Q4_K_M` → {family: "llama", version: "3.2", size: "3b", quant: "q4_k_m", type: "instruct"}
 *   - `mlx-community/Llama-3.2-3B-Instruct-4bit` → {family: "llama", version: "3.2", size: "3b", quant: "4bit", type: "instruct"}
 *   - `gemma:2b` → {family: "gemma", version: null, size: "2b", quant: null, type: "unknown"}
 */
export function parseModelName(input: string): ModelDescriptor {
  const original = input;
  // Strip namespace / org prefix (HuggingFace style "org/name" or "user/repo:tag")
  const afterSlash = input.includes("/") ? input.slice(input.lastIndexOf("/") + 1) : input;
  // Replace `:` with `-` (Ollama tag syntax). Keep underscores AS-IS so
  // quant tokens like `q4_k_m`, `q8_0`, `q4f16_1` survive tokenization
  // (the QUANT_ALIASES table indexes them with underscores). Keep periods
  // for version numbers like "3.2".
  const normalized = afterSlash
    .replace(/:/g, "-")
    .replace(/-?GGUF\b/gi, "")
    .replace(/-?ONNX\b/gi, "")
    .replace(/-?MLC\b/gi, "")
    .replace(/-?mlpackage\b/gi, "")
    .replace(/-?safetensors\b/gi, "")
    .replace(/^-+|-+$/g, "");

  const tokens = normalized
    .split("-")
    .map((t) => t.trim())
    .filter((t) => t.length > 0);

  let family = "unknown";
  let version: string | null = null;
  let size = "unknown";
  let quant: string | null = null;
  let type = "unknown";

  // First-pass: classify each token. Some tokens (family+version glommed
  // together like "llama3" or "gemma3n") need splitting.
  let i = 0;
  while (i < tokens.length) {
    const raw = tokens[i] ?? "";
    const t = raw.toLowerCase();

    // Family alias?
    if (family === "unknown" && FAMILY_ALIASES[t]) {
      family = FAMILY_ALIASES[t]!;
      i++;
      continue;
    }

    // Family+version glommed (e.g. "llama3", "gemma3n", "phi3")?
    const fv = FAMILY_VERSION_RE.exec(t);
    if (family === "unknown" && fv && FAMILY_ALIASES[fv[1]!]) {
      family = FAMILY_ALIASES[fv[1]!]!;
      version = fv[2]!;
      i++;
      continue;
    }

    // Standalone version following a known family?
    if (family !== "unknown" && version === null && VERSION_RE.test(t)) {
      version = t.replace(/^v/, "");
      i++;
      continue;
    }

    // Size alias?
    if (size === "unknown" && SIZE_ALIASES[t]) {
      size = SIZE_ALIASES[t]!;
      i++;
      continue;
    }

    // Quant alias?
    if (quant === null && QUANT_ALIASES[t]) {
      quant = QUANT_ALIASES[t]!;
      i++;
      continue;
    }

    // Type alias?
    if (type === "unknown" && TYPE_ALIASES[t]) {
      type = TYPE_ALIASES[t]!;
      i++;
      continue;
    }

    // Unrecognized token; skip + continue.
    i++;
  }

  return {
    family,
    version,
    size,
    quant,
    type,
    originalString: original,
  };
}

/**
 * Compare two quant levels via the QUANT_ORDER table.
 * Returns:
 *   - positive number if `a` is higher quality than `b`
 *   - negative number if `a` is lower quality than `b`
 *   - 0 if they're equal or either is unknown
 */
export function compareQuantQuality(a: string | null, b: string | null): number {
  if (a === null && b === null) return 0;
  if (a === null) return 1; // null = unquantized = best
  if (b === null) return -1;
  const ai = QUANT_ORDER.indexOf(a);
  const bi = QUANT_ORDER.indexOf(b);
  if (ai < 0 || bi < 0) return 0; // unknown quants are not comparable
  return ai - bi;
}

/**
 * Two descriptors describe the same model "shape" if their family,
 * version, size, and type all match. Quant is excluded — that's what
 * substitution may legitimately differ on (subject to policy).
 */
export function sameModelShape(a: ModelDescriptor, b: ModelDescriptor): boolean {
  return (
    a.family === b.family &&
    a.version === b.version &&
    a.size === b.size &&
    a.type === b.type
  );
}
