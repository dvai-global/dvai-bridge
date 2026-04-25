import { registerPlugin } from "@capacitor/core";
import type { NativePluginInterface } from "@dvai-bridge/capacitor";

const DVAIBridgeMediaPipe = registerPlugin<NativePluginInterface>("DVAIBridgeMediaPipe");

export default DVAIBridgeMediaPipe;
export { DVAIBridgeMediaPipe };
