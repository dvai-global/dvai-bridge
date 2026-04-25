import { registerPlugin } from "@capacitor/core";
import type { NativePluginInterface } from "@dvai-bridge/capacitor";

const DVAIBridgeFoundation = registerPlugin<NativePluginInterface>("DVAIBridgeFoundation");

export default DVAIBridgeFoundation;
export { DVAIBridgeFoundation };
