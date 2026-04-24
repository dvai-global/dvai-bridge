import { describe, it, expect } from "vitest";
import { createServer } from "node:http";

// Use a dedicated high range for tests so we don't collide with a
// dev-running DVAI on the default base port (38883).
const TEST_BASE = 39001;

describe("tryBind", () => {
  it("binds to the base port when free", async () => {
    const { tryBind } = await import("../transports/port-fallback");
    const server = createServer();
    try {
      const port = await tryBind(server, TEST_BASE, 4);
      expect(port).toBe(TEST_BASE);
    } finally {
      await new Promise<void>((r) => server.close(() => r()));
    }
  });

  it("retries +1 on EADDRINUSE and returns the next free port", async () => {
    const { tryBind } = await import("../transports/port-fallback");
    const blocker = createServer();
    await new Promise<void>((r) => blocker.listen(TEST_BASE + 10, "127.0.0.1", r));

    const server = createServer();
    try {
      const port = await tryBind(server, TEST_BASE + 10, 4);
      expect(port).toBe(TEST_BASE + 11);
    } finally {
      await new Promise<void>((r) => server.close(() => r()));
      await new Promise<void>((r) => blocker.close(() => r()));
    }
  });

  it("throws with actionable message after max attempts all blocked", async () => {
    const { tryBind } = await import("../transports/port-fallback");
    // Occupy TEST_BASE+20..TEST_BASE+23
    const blockers = await Promise.all(
      [0, 1, 2, 3].map((i) => {
        const s = createServer();
        return new Promise<typeof s>((r) => s.listen(TEST_BASE + 20 + i, "127.0.0.1", () => r(s)));
      }),
    );

    const server = createServer();
    try {
      await expect(tryBind(server, TEST_BASE + 20, 4)).rejects.toThrow(
        new RegExp(`${TEST_BASE + 20}\\.\\.${TEST_BASE + 23}`),
      );
    } finally {
      for (const b of blockers) await new Promise<void>((r) => b.close(() => r()));
    }
  });

  it("exports BASE_PORT = 38883 and MAX_PORT_ATTEMPTS = 16", async () => {
    const { BASE_PORT, MAX_PORT_ATTEMPTS } = await import("../transports/port-fallback");
    expect(BASE_PORT).toBe(38883);
    expect(MAX_PORT_ATTEMPTS).toBe(16);
  });
});
