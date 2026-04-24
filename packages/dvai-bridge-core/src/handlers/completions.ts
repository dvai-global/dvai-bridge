import type { HandlerContext } from "./context";

/**
 * Convert an OpenAI chat.completion response body into the legacy
 * text_completion shape used by POST /v1/completions.
 */
export function chatToLegacyCompletion(chatResp: any): any {
  return {
    id:
      (chatResp.id || "").replace("chatcmpl-", "cmpl-") || `cmpl-${Date.now()}`,
    object: "text_completion",
    created: chatResp.created ?? Math.floor(Date.now() / 1000),
    model: chatResp.model,
    choices: (chatResp.choices || []).map((c: any) => ({
      text: c.message?.content ?? "",
      index: c.index ?? 0,
      finish_reason: c.finish_reason ?? "stop",
      logprobs: null,
    })),
    usage: chatResp.usage ?? {
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: 0,
    },
  };
}

/**
 * Wraps an SSE stream of chat.completion.chunk events and rewrites each
 * event as a legacy text_completion chunk. Preserves event boundaries.
 */
export function legacyCompletionStreamAdapter(
  chatStream: ReadableStream<Uint8Array>,
  model: string,
): ReadableStream<Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let buffer = "";

  return new ReadableStream<Uint8Array>({
    async start(controller) {
      const reader = chatStream.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          let idx: number;
          while ((idx = buffer.indexOf("\n\n")) !== -1) {
            const rawEvent = buffer.slice(0, idx);
            buffer = buffer.slice(idx + 2);
            const dataLine = rawEvent
              .split("\n")
              .find((l) => l.startsWith("data:"));
            if (!dataLine) continue;
            const payload = dataLine.slice("data:".length).trim();
            if (payload === "[DONE]") {
              controller.enqueue(encoder.encode("data: [DONE]\n\n"));
              continue;
            }
            try {
              const chunk = JSON.parse(payload);
              const legacyChunk = {
                id: (chunk.id || "").replace("chatcmpl-", "cmpl-"),
                object: "text_completion.chunk",
                created: chunk.created,
                model: chunk.model || model,
                choices: (chunk.choices || []).map((c: any) => ({
                  text: c.delta?.content ?? "",
                  index: c.index ?? 0,
                  finish_reason: c.finish_reason ?? null,
                  logprobs: null,
                })),
              };
              controller.enqueue(
                encoder.encode(`data: ${JSON.stringify(legacyChunk)}\n\n`),
              );
            } catch {
              controller.enqueue(encoder.encode(`data: ${payload}\n\n`));
            }
          }
        }
      } finally {
        controller.close();
      }
    },
  });
}

export async function handleCompletion(
  body: any,
  ctx: HandlerContext,
): Promise<Response> {
  if (!ctx.backend) {
    return Response.json(
      { error: "AI engine not initialized" },
      { status: 503 },
    );
  }

  const promptField = body.prompt;
  const prompt = Array.isArray(promptField)
    ? promptField.join("\n")
    : (promptField ?? "");
  const chatBody = {
    ...body,
    messages: [{ role: "user", content: prompt }],
  };
  delete chatBody.prompt;

  try {
    if (chatBody.stream) {
      const chatStream = ctx.backend.createStreamingResponse(chatBody);
      const legacyStream = legacyCompletionStreamAdapter(
        chatStream,
        body.model || ctx.modelId,
      );
      return new Response(legacyStream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        },
      });
    }
    const chatResp = await ctx.backend.chatCompletion(chatBody);
    return Response.json(chatToLegacyCompletion(chatResp));
  } catch (error: any) {
    return Response.json({ error: error.message }, { status: 500 });
  }
}
