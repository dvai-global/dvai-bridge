import { registerPlugin } from "@capacitor/core";
import type { NativePluginInterface } from "@dvai-bridge/capacitor";

const DVAIBridgeLlama = registerPlugin<NativePluginInterface>("DVAIBridgeLlama");

export default DVAIBridgeLlama;
export { DVAIBridgeLlama };
