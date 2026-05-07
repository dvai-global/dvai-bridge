import { describe, it, expect } from "vitest";
import { parseModelName } from "../peer-mode/ModelParser.js";
import {
  SubstitutionPolicy,
  type BackendDescriptor,
} from "../peer-mode/SubstitutionPolicy.js";

function backend(modelString: string, engine = "builtin"): BackendDescriptor {
  return {
    descriptor: parseModelName(modelString),
    engine,
    engineModelId: modelString,
  };
}

describe("SubstitutionPolicy — exact matches", () => {
  it("returns 'exact' when all fields match", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: false });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [
      backend("Llama-3.2-3B-Instruct-Q4_K_M"),
      backend("Llama-3.2-3B-Instruct-Q8_0"),
    ];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("exact");
    if (decision.kind === "exact") {
      expect(decision.backend.engineModelId).toBe("Llama-3.2-3B-Instruct-Q4_K_M");
    }
  });

  it("returns 'exact' when both request and available have null quant", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: false });
    const request = parseModelName("Llama-3.2-3B-Instruct");
    const available = [backend("Llama-3.2-3B-Instruct")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("exact");
  });

  it("matches Ollama-style and GGUF-style with same descriptor as exact", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: false });
    // Both parse to the same descriptor (when versions are absent)
    const request = parseModelName("gemma:2b");
    const available = [backend("gemma-2b")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("exact");
  });

  it("first exact match wins even if multiple are present", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [
      backend("Llama-3.2-3B-Instruct-Q4_K_M", "engine1"),
      backend("Llama-3.2-3B-Instruct-Q4_K_M", "engine2"),
    ];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("exact");
    if (decision.kind === "exact") {
      expect(decision.backend.engine).toBe("engine1");
    }
  });

  it("returns 'refuse/no_backends' when available list is empty", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: false });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const decision = policy.pick(request, []);
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      expect(decision.reason).toBe("no_backends");
    }
  });
});

describe("SubstitutionPolicy — better quant substitution (preferBetterQuant=true)", () => {
  it("substitutes a strictly-better quant when permitted", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [backend("Llama-3.2-3B-Instruct-Q8_0")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("substituted");
    if (decision.kind === "substituted") {
      expect(decision.reason).toBe("better_quant");
      expect(decision.warning).toBe(false);
      expect(decision.backend.descriptor.quant).toBe("q8_0");
      expect(decision.replaced.from.quant).toBe("q4_k_m");
      expect(decision.replaced.to.quant).toBe("q8_0");
    }
  });

  it("substitutes worse-quant with warning when only worse is available", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q8_0");
    const available = [backend("Llama-3.2-3B-Instruct-Q4_K_M")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("substituted");
    if (decision.kind === "substituted") {
      expect(decision.reason).toBe("lower_quant");
      expect(decision.warning).toBe(true);
      expect(decision.backend.descriptor.quant).toBe("q4_k_m");
    }
  });

  it("picks the best-available better-quant when multiple are above the request", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_0");
    const available = [
      backend("Llama-3.2-3B-Instruct-Q5_K_M"),
      backend("Llama-3.2-3B-Instruct-Q8_0"),
      backend("Llama-3.2-3B-Instruct-Q4_K_M"),
    ];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("substituted");
    if (decision.kind === "substituted") {
      expect(decision.reason).toBe("better_quant");
      expect(decision.backend.descriptor.quant).toBe("q8_0");
    }
  });

  it("treats unspecified-quant request as 'pick best available' (warning=false)", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: false });
    const request = parseModelName("Llama-3.2-3B-Instruct");
    const available = [
      backend("Llama-3.2-3B-Instruct-Q4_K_M"),
      backend("Llama-3.2-3B-Instruct-Q8_0"),
    ];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("substituted");
    if (decision.kind === "substituted") {
      expect(decision.reason).toBe("exact_quant_unspecified");
      expect(decision.warning).toBe(false);
      expect(decision.backend.descriptor.quant).toBe("q8_0");
    }
  });

  it("doesn't substitute quant when preferBetterQuant=false (refuse)", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: false });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [backend("Llama-3.2-3B-Instruct-Q8_0")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      expect(decision.reason).toBe("quant_mismatch_strict");
    }
  });
});

describe("SubstitutionPolicy — refuses on shape mismatch", () => {
  it("refuses when family differs", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [backend("gemma-3-3B-Instruct-Q4_K_M")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      expect(decision.reason).toBe("family_mismatch");
    }
  });

  it("refuses when version differs", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [backend("Llama-3.1-3B-Instruct-Q4_K_M")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      expect(decision.reason).toBe("version_mismatch");
    }
  });

  it("refuses when size differs", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [backend("Llama-3.2-1B-Instruct-Q4_K_M")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      expect(decision.reason).toBe("size_mismatch");
    }
  });

  it("refuses when type differs (e.g. instruct vs chat)", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [backend("Llama-3.2-3B-Chat-Q4_K_M")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      expect(decision.reason).toBe("type_mismatch");
    }
  });

  it("refuses when type differs even with preferBetterQuant=true (type is sacred)", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [backend("Llama-3.2-3B-Code-Q8_0")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      expect(decision.reason).toBe("type_mismatch");
    }
  });

  it("returns the closest-shape mismatch reason when multiple non-matches are available", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [
      backend("gemma-3-3B-Instruct-Q4_K_M"),     // family mismatch
      backend("Llama-3.2-1B-Instruct-Q4_K_M"),    // size mismatch (closer)
    ];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      // size-mismatch is closer than family-mismatch (3 fields match vs 1)
      expect(decision.reason).toBe("size_mismatch");
    }
  });
});

describe("SubstitutionPolicy — audit/warning surface", () => {
  it("emits warning=true on lower-quant substitution so caller can audit-log it", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q8_0");
    const available = [backend("Llama-3.2-3B-Instruct-Q4_0")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("substituted");
    if (decision.kind === "substituted") {
      expect(decision.warning).toBe(true);
      expect(decision.reason).toBe("lower_quant");
    }
  });

  it("emits warning=false on better-quant substitution (no audit alarm needed)", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_0");
    const available = [backend("Llama-3.2-3B-Instruct-Q8_0")];
    const decision = policy.pick(request, available);
    expect(decision.kind).toBe("substituted");
    if (decision.kind === "substituted") {
      expect(decision.warning).toBe(false);
      expect(decision.reason).toBe("better_quant");
    }
  });

  it("includes from/to descriptors in the substituted decision", () => {
    const policy = new SubstitutionPolicy({ preferBetterQuant: true });
    const request = parseModelName("Llama-3.2-3B-Instruct-Q4_K_M");
    const available = [backend("Llama-3.2-3B-Instruct-Q8_0")];
    const decision = policy.pick(request, available);
    if (decision.kind === "substituted") {
      expect(decision.replaced.from.quant).toBe("q4_k_m");
      expect(decision.replaced.to.quant).toBe("q8_0");
      expect(decision.replaced.from.family).toBe("llama");
      expect(decision.replaced.to.family).toBe("llama");
    } else {
      throw new Error("expected substituted");
    }
  });
});
