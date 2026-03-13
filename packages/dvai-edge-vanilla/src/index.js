import { DvAI } from "dvai-edge-core";

export class VanillaDvAI {
  constructor(config = {}) {
    this.core = new DvAI(config);
    this.isReady = false;
    this.progressText = "";
    this.mockUrl = this.core.mockUrl;
    this.modelId = this.core.modelId;
    this.listeners = new Set();
  }

  async initialize() {
    await this.core.initialize(
      (progress) => {
        this.progressText = progress.text;
        this.notifyListeners();
      },
      (ready) => {
        this.isReady = ready;
        this.notifyListeners();
      }
    );
  }

  subscribe(listener) {
    this.listeners.add(listener);
    // Send initial state immediately
    listener(this.getState());
    return () => {
      this.listeners.delete(listener);
    };
  }

  notifyListeners() {
    const state = this.getState();
    this.listeners.forEach((listener) => listener(state));
  }

  getState() {
    return {
      isReady: this.isReady,
      progress: this.progressText,
      mockUrl: this.mockUrl,
      modelId: this.modelId,
    };
  }
}

// Attach to global window object for browser `<script>` usage
if (typeof window !== "undefined") {
  window.VanillaDvAI = VanillaDvAI;
}

export default VanillaDvAI;
