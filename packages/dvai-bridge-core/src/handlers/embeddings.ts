import type { HandlerContext } from "./context";

export async function handleEmbeddings(
  body: any,
  ctx: HandlerContext,
): Promise<Response> {
  if (!ctx.backend) {
    return Response.json(
      { error: "AI engine not initialized" },
      { status: 503 },
    );
  }
  if (ctx.resolvedBackend === "webllm") {
    return Response.json(
      {
        error:
          "Embeddings are not supported on the WebLLM backend. " +
          "Use backend: 'transformers' with pipelineTask: 'feature-extraction'.",
      },
      { status: 400 },
    );
  }
  if (typeof ctx.backend.embedding !== "function") {
    return Response.json(
      {
        error:
          "The current backend does not support embeddings. " +
          "For transformers: use pipelineTask: 'feature-extraction'.",
      },
      { status: 400 },
    );
  }

  const input = body?.input;
  if (input === undefined || input === null) {
    return Response.json(
      { error: "Missing 'input' field." },
      { status: 400 },
    );
  }

  try {
    const vectors: number[][] = await ctx.backend.embedding(input);
    return Response.json({
      object: "list",
      data: vectors.map((v, i) => ({
        object: "embedding",
        embedding: v,
        index: i,
      })),
      model: body.model || ctx.modelId,
      usage: { prompt_tokens: 0, total_tokens: 0 },
    });
  } catch (error: any) {
    return Response.json({ error: error.message }, { status: 500 });
  }
}
