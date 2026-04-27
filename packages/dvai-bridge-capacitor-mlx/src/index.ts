import { registerPlugin } from "@capacitor/core";
import type { NativePluginInterface } from "@dvai-bridge/capacitor";

const DVAIBridgeMLX = registerPlugin<NativePluginInterface>("DVAIBridgeMLX");

export default DVAIBridgeMLX;
export { DVAIBridgeMLX };
