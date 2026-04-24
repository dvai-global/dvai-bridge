import type { HandlerContext } from "../handlers/context.js";
import {
  handleChatCompletion,
  handleCompletion,
  handleEmbeddings,
  handleModels,
} from "../handlers/index.js";
import type {
  HttpTransportOptions,
  Transport,
  TransportStartResult,
} from "./types.js";
import { tryBind } from "./port-fallback.js";

type NodeReq = import("node:http").IncomingMessage;
type NodeRes = import("node:http").ServerResponse;
type NodeServer = import("node:http").Server;

function pickOrigin(origin: string | undefined, cfg: string | string[]): string | null {
  if (cfg === "*") return "*";
  if (typeof cfg === "string") return cfg;
  if (!origin) return null;
  return cfg.includes(origin) ? origin : null;
}

function corsHeaders(
  reqOrigin: string | undefined,
  cfg: string | string[],
): Record<string, string> {
  const allow = pickOrigin(reqOrigin, cfg);
  const headers: Record<string, string> = {
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Private-Network": "true",
  };
  if (allow) headers["Access-Control-Allow-Origin"] = allow;
  return headers;
}

async function readJsonBody(req: NodeReq): Promise<any> {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error("Invalid JSON body");
  }
}

async function writeWhatwgResponse(
  res: NodeRes,
  response: Response,
  extraHeaders: Record<string, string>,
): Promise<void> {
  const headers: Record<string, string> = { ...extraHeaders };
  response.headers.forEach((v, k) => {
    headers[k] = v;
  });

  if (response.body) {
    res.writeHead(response.status, headers);
    const reader = response.body.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(Buffer.from(value));
      }
    } finally {
      res.end();
    }
    return;
  }
  const text = await response.text();
  res.writeHead(response.status, headers);
  res.end(text);
}

async function route(
  req: NodeReq,
  res: NodeRes,
  ctx: HandlerContext,
  opts: HttpTransportOptions,
): Promise<void> {
  const reqOrigin = req.headers.origin as string | undefined;
  const cors = corsHeaders(reqOrigin, opts.corsOrigin);

  if (req.method === "OPTIONS") {
    res.writeHead(204, cors);
    res.end();
    return;
  }

  const url = new URL(req.url || "/", "http://127.0.0.1");
  const path = url.pathname;

  try {
    if (req.method === "POST" && path === "/v1/chat/completions") {
      const body = await readJsonBody(req);
      const r = await handleChatCompletion(body, ctx);
      return writeWhatwgResponse(res, r, cors);
    }
    if (req.method === "POST" && path === "/v1/completions") {
      const body = await readJsonBody(req);
      const r = await handleCompletion(body, ctx);
      return writeWhatwgResponse(res, r, cors);
    }
    if (req.method === "POST" && path === "/v1/embeddings") {
      const body = await readJsonBody(req);
      const r = await handleEmbeddings(body, ctx);
      return writeWhatwgResponse(res, r, cors);
    }
    if (req.method === "GET" && path === "/v1/models") {
      const r = await handleModels(ctx);
      return writeWhatwgResponse(res, r, cors);
    }
    res.writeHead(404, { ...cors, "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
  } catch (err: any) {
    res.writeHead(500, { ...cors, "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: err?.message ?? "unknown error" }));
  }
}

export class HttpTransport implements Transport {
  readonly kind = "http" as const;
  private server: NodeServer | null = null;
  private boundPort: number | undefined;

  constructor(private readonly opts: HttpTransportOptions) {}

  async start(ctx: HandlerContext): Promise<TransportStartResult> {
    const { createServer } = await import("node:http");
    const server = createServer((req, res) => {
      route(req, res, ctx, this.opts).catch((err) => {
        try {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: (err as Error).message }));
        } catch {
          /* socket already closed */
        }
      });
    });
    const port = await tryBind(server, this.opts.httpBasePort, this.opts.httpMaxPortAttempts);
    this.server = server;
    this.boundPort = port;
    return { baseUrl: `http://127.0.0.1:${port}/v1`, port };
  }

  async stop(): Promise<void> {
    if (this.server) {
      await new Promise<void>((r) => this.server!.close(() => r()));
      this.server = null;
      this.boundPort = undefined;
    }
  }
}
