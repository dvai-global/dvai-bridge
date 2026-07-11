import { registerPlugin } from "@capacitor/core";
import type { NativePluginInterface } from "@dvai-bridge/capacitor";

const DVAIBridgeLiteRTLM = registerPlugin<NativePluginInterface>("DVAIBridgeLiteRTLM");

export default DVAIBridgeLiteRTLM;
export { DVAIBridgeLiteRTLM };
