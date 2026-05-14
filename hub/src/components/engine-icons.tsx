/**
 * Inline SVG marks for every engine card. Lucide doesn't have brand
 * icons for Ollama / LM Studio / vLLM / llamafile / llama-server /
 * Transformers.js / node-llama-cpp, so we ship minimal but recognisable
 * inline SVG components here. Each accepts `size` + `className` so the
 * caller can colour-treat it the same way as a lucide icon.
 *
 * The shapes are deliberately simplified glyphs (silhouettes, monograms)
 * rather than pixel-accurate trademarks — sufficient for at-a-glance
 * recognition in a 40px card chip while avoiding any logo-fidelity
 * issues at small sizes.
 */
import type { JSX } from "react";

interface IconProps {
  size?: number;
  className?: string;
}

/* Ollama — alpaca silhouette monogram (rounded "O" with ears). */
function OllamaIcon({ size = 20, className }: IconProps): JSX.Element {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      className={className}
      aria-hidden="true"
    >
      <path
        d="M7 4c-1 0-1.8 0.8-1.8 1.8v2.4C3.7 9.5 3 11.3 3 13.3 3 17.5 7 21 12 21s9-3.5 9-7.7c0-2-0.7-3.8-2.2-5.1V5.8C18.8 4.8 18 4 17 4c-0.9 0-1.6 0.6-1.8 1.4-1-0.3-2.1-0.4-3.2-0.4s-2.2 0.1-3.2 0.4C8.6 4.6 7.9 4 7 4Z"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinejoin="round"
        fill="currentColor"
        fillOpacity="0.15"
      />
      <circle cx="9.5" cy="13" r="1" fill="currentColor" />
      <circle cx="14.5" cy="13" r="1" fill="currentColor" />
      <path
        d="M10 16.5c0.5 0.5 1.2 0.8 2 0.8s1.5-0.3 2-0.8"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        fill="none"
      />
    </svg>
  );
}

/* LM Studio — three stacked horizontal bars (their visual hallmark). */
function LmStudioIcon({ size = 20, className }: IconProps): JSX.Element {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      className={className}
      aria-hidden="true"
    >
      <rect
        x="4"
        y="6"
        width="16"
        height="3.2"
        rx="1.2"
        fill="currentColor"
        opacity="0.95"
      />
      <rect
        x="4"
        y="10.4"
        width="16"
        height="3.2"
        rx="1.2"
        fill="currentColor"
        opacity="0.65"
      />
      <rect
        x="4"
        y="14.8"
        width="16"
        height="3.2"
        rx="1.2"
        fill="currentColor"
        opacity="0.35"
      />
    </svg>
  );
}

/* vLLM — bold "V" monogram in a rounded square. */
function VllmIcon({ size = 20, className }: IconProps): JSX.Element {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      className={className}
      aria-hidden="true"
    >
      <rect
        x="3"
        y="3"
        width="18"
        height="18"
        rx="4"
        stroke="currentColor"
        strokeWidth="1.6"
        fill="currentColor"
        fillOpacity="0.1"
      />
      <path
        d="M7.5 8.5l4.5 8.5 4.5-8.5"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        fill="none"
      />
    </svg>
  );
}

/* llamafile — file icon with a small llama silhouette inside. */
function LlamafileIcon({ size = 20, className }: IconProps): JSX.Element {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      className={className}
      aria-hidden="true"
    >
      <path
        d="M6 3h8l5 5v12c0 1.1-0.9 2-2 2H6c-1.1 0-2-0.9-2-2V5c0-1.1 0.9-2 2-2Z"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinejoin="round"
        fill="currentColor"
        fillOpacity="0.1"
      />
      <path d="M14 3v5h5" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" fill="none" />
      <path
        d="M8.5 16c0-1.5 1.2-2.5 2.5-2.5 0.7 0 1.3 0.3 1.8 0.8 0.4-0.3 0.9-0.5 1.5-0.5 1.3 0 2.2 1 2.2 2.2v1.5h-8V16Z"
        fill="currentColor"
        opacity="0.85"
      />
    </svg>
  );
}

/* llama.cpp HTTP server — terminal box with gear (the server tool). */
function LlamaServerIcon({ size = 20, className }: IconProps): JSX.Element {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      className={className}
      aria-hidden="true"
    >
      <rect
        x="3"
        y="4"
        width="18"
        height="13"
        rx="2"
        stroke="currentColor"
        strokeWidth="1.6"
        fill="currentColor"
        fillOpacity="0.1"
      />
      <path d="M7 9l3 2.5L7 14" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" fill="none" />
      <line x1="12" y1="14" x2="17" y2="14" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      <line x1="8" y1="20" x2="16" y2="20" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      <line x1="12" y1="17" x2="12" y2="20" stroke="currentColor" strokeWidth="1.6" />
    </svg>
  );
}

/* Transformers.js — HuggingFace-inspired smiley silhouette. */
function TransformersIcon({ size = 20, className }: IconProps): JSX.Element {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      className={className}
      aria-hidden="true"
    >
      <circle
        cx="12"
        cy="12"
        r="9"
        stroke="currentColor"
        strokeWidth="1.6"
        fill="currentColor"
        fillOpacity="0.12"
      />
      <ellipse cx="9" cy="10.5" rx="1" ry="1.5" fill="currentColor" />
      <ellipse cx="15" cy="10.5" rx="1" ry="1.5" fill="currentColor" />
      <path
        d="M8 14.5c0.8 1.5 2.3 2.5 4 2.5s3.2-1 4-2.5"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        fill="none"
      />
    </svg>
  );
}

/* node-llama-cpp — chip with a small llama ear. */
function NodeLlamaCppIcon({ size = 20, className }: IconProps): JSX.Element {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      className={className}
      aria-hidden="true"
    >
      <rect
        x="5"
        y="5"
        width="14"
        height="14"
        rx="2"
        stroke="currentColor"
        strokeWidth="1.6"
        fill="currentColor"
        fillOpacity="0.12"
      />
      <rect
        x="8"
        y="8"
        width="8"
        height="8"
        rx="1"
        stroke="currentColor"
        strokeWidth="1.4"
        fill="none"
      />
      <line x1="2.5" y1="9" x2="5" y2="9" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      <line x1="2.5" y1="15" x2="5" y2="15" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      <line x1="19" y1="9" x2="21.5" y2="9" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      <line x1="19" y1="15" x2="21.5" y2="15" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      <line x1="9" y1="2.5" x2="9" y2="5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      <line x1="15" y1="2.5" x2="15" y2="5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      <line x1="9" y1="19" x2="9" y2="21.5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      <line x1="15" y1="19" x2="15" y2="21.5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}

/**
 * Resolve an engine name (the `EngineSummary.name` field, case-
 * insensitive substring match) to a brand icon component. Returns
 * `null` if no brand match — caller falls back to a generic icon.
 */
export function iconForEngineName(
  name: string,
): ((props: IconProps) => JSX.Element) | null {
  const n = name.toLowerCase();
  // External adapters — match against the EngineAdapter.name field.
  if (n === "ollama") return OllamaIcon;
  if (n === "lmstudio" || n === "lm-studio" || n.includes("lm studio")) return LmStudioIcon;
  if (n === "vllm") return VllmIcon;
  if (n === "llamafile") return LlamafileIcon;
  if (n.includes("llama-server") || n === "llamaserver") return LlamaServerIcon;
  // Internal engines — match against the InternalEngineConfig.name
  // display strings used in server.ts (e.g. "Transformers.js (Internal)").
  if (n.includes("transformers")) return TransformersIcon;
  if (n.includes("llama.cpp") || n.includes("node-llama-cpp")) return NodeLlamaCppIcon;
  return null;
}
