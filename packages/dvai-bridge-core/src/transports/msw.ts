import { setupWorker, type SetupWorker } from "msw/browser";
import { http } from "msw";
import type { HandlerContext } from "../handlers/context.js";
import {
  handleChatCompletion,
  handleCompletion,
  handleEmbeddings,
  handleModels,
} from "../handlers/index.js";
import type {
  MswTransportOptions,
  Transport,
  TransportStartResult,
} from "./types.js";

function getEndpoints(mockUrl: string): {
  chat: string;
  completions: string;
  embeddings: string;
  models: string;
  base: string;
} {
  const chat = mockUrl;
  let base = chat;
  const chatSuffix = "/chat/completions";
  if (chat.endsWith(chatSuffix)) {
    base = chat.slice(0, -chatSuffix.length);
  } else {
    try {
      const u = new URL(chat);
      const parts = u.pathname.split("/").filter(Boolean);
      parts.pop();
      u.pathname = "/" + parts.join("/");
      base = u.toString().replace(/\/$/, "");
    } catch {
      /* keep base = chat */
    }
  }
  return {
    chat,
    completions: `${base}/completions`,
    embeddings: `${base}/embeddings`,
    models: `${base}/models`,
    base,
  };
}

export class MswTransport implements Transport {
  readonly kind = "msw" as const;
  private worker: SetupWorker | null = null;

  constructor(private readonly opts: MswTransportOptions) {}

  async start(ctx: HandlerContext): Promise<TransportStartResult> {
    const urls = getEndpoints(this.opts.mockUrl);

    // Empty serviceWorkerUrl means "don't register" — preserves the
    // direct-inference escape hatch while still reporting a baseUrl.
    if (this.opts.serviceWorkerUrl) {
      const handlers = [
        http.post(urls.chat, async ({ request }) =>
          handleChatCompletion(await request.json(), ctx),
        ),
        http.post(urls.completions, async ({ request }) =>
          handleCompletion(await request.json(), ctx),
        ),
        http.post(urls.embeddings, async ({ request }) =>
          handleEmbeddings(await request.json(), ctx),
        ),
        http.get(urls.models, async () => handleModels(ctx)),
      ];
      this.worker = setupWorker(...handlers);
      await this.worker.start({
        onUnhandledRequest: "bypass",
        serviceWorker: { url: this.opts.serviceWorkerUrl },
      } as any);
    }

    return { baseUrl: urls.base };
  }

  async stop(): Promise<void> {
    if (this.worker) {
      this.worker.stop();
      this.worker = null;
    }
  }
}
