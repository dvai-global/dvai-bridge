import type { HandlerContext } from "./context";

const SSE_HEADERS = {
  "Content-Type": "text/event-stream",
  "Cache-Control": "no-cache",
  Connection: "keep-alive",
};

export async function handleChatCompletion(
  body: any,
  ctx: HandlerContext,
  headers?: Record<string, string>,
): Promise<Response> {
  // Phase 4 — first-chance interceptor (used by the Hub to enforce
  // substitution policy + route through external engines). If it
  // returns a Response, we're done; null falls through to the local
  // backend path below.
  if (ctx.chatCompletionInterceptor) {
    try {
      const intercepted = await ctx.chatCompletionInterceptor(body, ctx, headers);
      if (intercepted !== null) return intercepted;
    } catch (err: any) {
      return Response.json(
        { error: err?.message ?? "interceptor failed" },
        { status: 500 },
      );
    }
  }

  if (!ctx.backend) {
    return Response.json(
      { error: "AI engine not initialized" },
      { status: 503 },
    );
  }

  // Always read ctx.backend inside runOnce so that if onRecovery replaces
  // the underlying backend instance, the retry hits the new one.
  const runOnce = async (): Promise<Response> => {
    const backend = ctx.backend;
    if (!backend) {
      return Response.json(
        { error: "AI engine not initialized" },
        { status: 503 },
      );
    }
    if (body.stream) {
      const stream = backend.createStreamingResponse(body);
      return new Response(stream, { headers: SSE_HEADERS });
    }
    const response = await backend.chatCompletion(body);
    return Response.json(response);
  };

  try {
    // Proactive recovery: if the backend is flagged with a prior fatal error,
    // ask DVAI to recover before the attempt.
    if (ctx.backend.lastFatalError && ctx.onRecovery) {
      await ctx.onRecovery();
    }
    return await runOnce();
  } catch (error: any) {
    // Reactive recovery: if the backend flags a fatal error during the attempt,
    // recover and retry once. DVAI's onRecovery throws when exhausted, which
    // falls through to the 500 response below.
    if (ctx.backend?.lastFatalError && ctx.onRecovery) {
      try {
        await ctx.onRecovery();
        return await runOnce();
      } catch {
        /* fall through to 500 */
      }
    }
    return Response.json({ error: error.message }, { status: 500 });
  }
}
