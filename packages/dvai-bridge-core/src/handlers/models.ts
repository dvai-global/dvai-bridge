import type { HandlerContext } from "./context";

export async function handleModels(ctx: HandlerContext): Promise<Response> {
  return Response.json({
    object: "list",
    data: [
      {
        id: ctx.modelId,
        object: "model",
        created: Math.floor(Date.now() / 1000),
        owned_by: "dvai-bridge",
      },
    ],
  });
}
