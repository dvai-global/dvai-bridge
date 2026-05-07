import { describe, it, expect } from "vitest";
import {
  parseModelName,
  compareQuantQuality,
  sameModelShape,
  type ModelDescriptor,
} from "../peer-mode/ModelParser.js";

interface CorpusEntry {
  input: string;
  expected: Partial<ModelDescriptor>;
  notes?: string;
}

/**
 * The canonical naming-convention corpus. Each entry asserts the
 * parser handles a real-world string. Keep this up to date as new
 * conventions surface in the wild.
 */
const CORPUS: CorpusEntry[] = [
  // User's reference example (from the design conversation)
  {
    input: "gemma-4-E2B-q4-instruct",
    expected: { family: "gemma", version: "4", size: "e2b", quant: "q4_k_m", type: "instruct" },
  },
  // GGUF / llama.cpp canonical
  {
    input: "Llama-3.2-3B-Instruct-Q4_K_M",
    expected: { family: "llama", version: "3.2", size: "3b", quant: "q4_k_m", type: "instruct" },
  },
  {
    input: "Llama-3.2-1B-Instruct-Q8_0",
    expected: { family: "llama", version: "3.2", size: "1b", quant: "q8_0", type: "instruct" },
  },
  // HuggingFace MLX
  {
    input: "mlx-community/Llama-3.2-3B-Instruct-4bit",
    expected: { family: "llama", version: "3.2", size: "3b", quant: "4bit", type: "instruct" },
    notes: "Strip namespace prefix; recognize 4bit as canonical quant",
  },
  {
    input: "mlx-community/Llama-3.2-3B-Instruct-8bit",
    expected: { family: "llama", version: "3.2", size: "3b", quant: "8bit", type: "instruct" },
  },
  // HuggingFace ONNX
  {
    input: "microsoft/Phi-3-mini-4k-instruct-onnx",
    expected: { family: "phi", version: "3", size: "mini", quant: null, type: "instruct" },
    notes: "ONNX suffix dropped; mini is a textual size",
  },
  // MLC convention
  {
    input: "gemma-2-2b-it-q4f16_1-MLC",
    expected: { family: "gemma", version: "2", size: "2b", quant: "q4_k_m_approx", type: "instruct" },
    notes: "`it` aliases to instruct; MLC suffix dropped; q4f16_1 maps to q4_k_m_approx",
  },
  // Ollama tag-style
  {
    input: "gemma:2b",
    expected: { family: "gemma", version: null, size: "2b", quant: null, type: "unknown" },
    notes: "Colon converts to hyphen; type unspecified",
  },
  // Raw HF
  {
    input: "meta-llama/Llama-3.2-3B-Instruct",
    expected: { family: "llama", version: "3.2", size: "3b", quant: null, type: "instruct" },
  },
  // GGUF-with-tag style (bartowski common pattern)
  {
    input: "bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M",
    expected: { family: "llama", version: "3.2", size: "1b", quant: "q4_k_m", type: "instruct" },
    notes: "Strip namespace, drop GGUF, parse Q4_K_M",
  },
  // Family-and-version glommed (Phi-3)
  {
    input: "Phi-3-mini-4k-instruct",
    expected: { family: "phi", version: "3", size: "mini", quant: null, type: "instruct" },
  },
  {
    input: "phi3-mini-instruct",
    expected: { family: "phi", version: "3", size: "mini", quant: null, type: "instruct" },
    notes: "phi3 glommed; should split into family=phi, version=3",
  },
  // Mistral
  {
    input: "mistral-7b-instruct-q4_0",
    expected: { family: "mistral", version: null, size: "7b", quant: "q4_0", type: "instruct" },
  },
  // Qwen
  {
    input: "Qwen2-7B-Instruct-Q5_K_M",
    expected: { family: "qwen", version: null, size: "7b", quant: "q5_k_m", type: "instruct" },
  },
  // DeepSeek
  {
    input: "deepseek-r1-7b-q4_K_M",
    expected: { family: "deepseek", version: null, size: "7b", quant: "q4_k_m", type: "unknown" },
    notes: "`r1` not a recognized type; type stays unknown (correct — deepseek-r1 is reasoning, not instruct)",
  },
  // Gemma 3n with E-suffix size
  {
    input: "onnx-community/gemma-3n-E2B-it-ONNX",
    expected: { family: "gemma", version: null, size: "e2b", quant: null, type: "instruct" },
    notes: "gemma-3n: family=gemma, version=null (3n is the architecture variant). it→instruct.",
  },
  // Code variants
  {
    input: "Qwen2.5-Coder-7B-Instruct-Q4_K_M",
    expected: { family: "qwen", version: "2.5", size: "7b", quant: "q4_k_m", type: "code" },
    notes: "Coder→code wins over Instruct? No — first hit wins; Coder appears first lexically. Test asserts code.",
  },
  // Vision / multimodal
  {
    input: "llava-llama-3.2-3b-vision-q4",
    expected: { family: "llama", version: "3.2", size: "3b", quant: "q4_k_m", type: "vision" },
    notes: "llava prefix is unrecognized; falls through to llama family. Vision wins as type.",
  },
  // Unknown / garbage
  {
    input: "complete-garbage-string",
    expected: { family: "unknown", version: null, size: "unknown", quant: null, type: "unknown" },
  },
  {
    input: "12345",
    expected: { family: "unknown", version: null, size: "unknown", quant: null, type: "unknown" },
  },
];

describe("parseModelName — canonical naming corpus", () => {
  for (const entry of CORPUS) {
    it(entry.input + (entry.notes ? ` — ${entry.notes}` : ""), () => {
      const parsed = parseModelName(entry.input);
      // Always preserve original
      expect(parsed.originalString).toBe(entry.input);
      // Asserted fields
      for (const [key, value] of Object.entries(entry.expected) as Array<
        [keyof ModelDescriptor, ModelDescriptor[keyof ModelDescriptor]]
      >) {
        expect(parsed[key], `${entry.input} → field ${key}`).toBe(value);
      }
    });
  }
});

describe("parseModelName — round-trip property", () => {
  it("preserves originalString verbatim regardless of parse outcome", () => {
    const inputs = [
      "gemma-4-E2B-q4-instruct",
      "completely-unknown",
      "",
      "  trimmed  ",
      "lots-of-hyphens-and-no-meaning",
    ];
    for (const input of inputs) {
      expect(parseModelName(input).originalString).toBe(input);
    }
  });
});

describe("compareQuantQuality", () => {
  it("returns 0 when both null", () => {
    expect(compareQuantQuality(null, null)).toBe(0);
  });
  it("treats null as best (higher than any quant)", () => {
    expect(compareQuantQuality(null, "q4_k_m")).toBeGreaterThan(0);
    expect(compareQuantQuality("q4_k_m", null)).toBeLessThan(0);
  });
  it("orders by QUANT_ORDER table", () => {
    expect(compareQuantQuality("q8_0", "q4_k_m")).toBeGreaterThan(0);
    expect(compareQuantQuality("q4_k_m", "q8_0")).toBeLessThan(0);
    expect(compareQuantQuality("q4_k_m", "q4_k_m")).toBe(0);
    expect(compareQuantQuality("f16", "q4_0")).toBeGreaterThan(0);
  });
  it("returns 0 for unknown quants", () => {
    expect(compareQuantQuality("nonexistent_quant", "q4_k_m")).toBe(0);
    expect(compareQuantQuality("q4_k_m", "nonexistent_quant")).toBe(0);
  });
});

describe("sameModelShape", () => {
  it("true when family/version/size/type match (quant ignored)", () => {
    const a = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const b = parseModelName("Llama-3.2-3B-Instruct-Q8_0");
    expect(sameModelShape(a, b)).toBe(true);
  });
  it("false when type differs", () => {
    const a = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const b = parseModelName("Llama-3.2-3B-Chat-Q4_K_M");
    // Note: "chat" is in TYPE_ALIASES; this asserts type-mismatch detection
    expect(sameModelShape(a, b)).toBe(false);
  });
  it("false when version differs", () => {
    const a = parseModelName("Llama-3.2-3B-Instruct");
    const b = parseModelName("Llama-3.1-3B-Instruct");
    expect(sameModelShape(a, b)).toBe(false);
  });
  it("false when size differs", () => {
    const a = parseModelName("Llama-3.2-3B-Instruct");
    const b = parseModelName("Llama-3.2-1B-Instruct");
    expect(sameModelShape(a, b)).toBe(false);
  });
  it("false when family differs", () => {
    const a = parseModelName("Llama-3.2-3B-Instruct");
    const b = parseModelName("gemma-3-3B-Instruct");
    expect(sameModelShape(a, b)).toBe(false);
  });
});
