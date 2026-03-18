import { ssrRenderAttrs } from "vue/server-renderer";
import { useSSRContext } from "vue";
import { _ as _export_sfc } from "./plugin-vue_export-helper.1tPrXgE0.js";
const __pageData = JSON.parse('{"title":"","description":"","frontmatter":{"layout":"home","hero":{"name":"DvAI-Edge","text":"Local AI Orchestration","tagline":"Unified LLM inference for Web, Capacitor, and Electron with zero cloud costs.","image":{"src":"/banner.png","alt":"DvAI-Edge Banner"},"actions":[{"theme":"brand","text":"Get Started","link":"/guide/getting-started"},{"theme":"alt","text":"View on GitHub","link":"https://github.com/Westenets/dvai-edge"}]},"features":[{"title":"🚀 Multi-Backend","details":"Seamlessly switch between WebLLM (WebGPU), Transformers.js, and Native LLMs via `llama-cpp-capacitor`."},{"title":"🛡️ Auto-Recovery","details":"Built-in robustness for WebLLM with automatic recovery from blank outputs and timeouts."},{"title":"📱 Native Support","details":"High-performance GGUF model support on iOS and Android via a native Capacitor plugin."},{"title":"⚛️ First-class React","details":"Easy-to-use Hooks and Providers for React, with full TypeScript support and auto-initialization."},{"title":"🍦 Vanilla JS Support","details":"Works in any environment (Vanilla JS, Vue, Svelte, Angular) via a lightweight, framework-agnostic wrapper."},{"title":"🤖 Agent SDK Ready","details":"Fully compatible with LangChain, Vercel AI SDK, and more via a local OpenAI-compatible API interface."},{"title":"🎨 Multi-Modal","details":"Support for Text, Image, Audio, and Video tasks via Transformers.js (Multi-modality coming soon for all backends)."},{"title":"📦 Hybrid Model Handling","details":"Automatic backend selection based on the environment (Web, Mobile, or Electron)."},{"title":"🔒 100% Local & Private","details":"Zero API costs, zero server maintenance, and maximum user privacy. Your data never leaves the device."}]},"headers":[],"relativePath":"index.md","filePath":"index.md"}');
const _sfc_main = { name: "index.md" };
function _sfc_ssrRender(_ctx, _push, _parent, _attrs, $props, $setup, $data, $options) {
  _push(`<div${ssrRenderAttrs(_attrs)}></div>`);
}
const _sfc_setup = _sfc_main.setup;
_sfc_main.setup = (props, ctx) => {
  const ssrContext = useSSRContext();
  (ssrContext.modules || (ssrContext.modules = /* @__PURE__ */ new Set())).add("index.md");
  return _sfc_setup ? _sfc_setup(props, ctx) : void 0;
};
const index = /* @__PURE__ */ _export_sfc(_sfc_main, [["ssrRender", _sfc_ssrRender]]);
export {
  __pageData,
  index as default
};
