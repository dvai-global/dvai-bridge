/**
 * macOS-native mDNS advertiser via the system `dns-sd` CLI.
 *
 * Why this exists: the Hub's JS-core advertise path uses
 * `multicast-dns` (`packages/dvai-bridge-core/src/discovery/
 * mdns-node.ts`), which can't actually broadcast on macOS. Apple's
 * `mDNSResponder` daemon owns UDP port 5353 first, so the npm lib's
 * raw-socket `bind(5353)` silently fails AND its multicast SENDS
 * never propagate as authoritative `_dvai-bridge._tcp` announcements
 * (verified via `dns-sd -B _dvai-bridge._tcp` from the same Mac).
 * Result: paired iOS clients couldn't see the Hub on the LAN and
 * had to paste its URL manually — a v3.2.0 dogfood blocker.
 *
 * The fix is to delegate to `mDNSResponder` via the system `dns-sd`
 * CLI (shipped with macOS, no extra deps). `dns-sd -R <name> <type>
 * <domain> <port> [key=value]...` registers a service that other
 * Bonjour-aware clients (NWBrowser on iOS, the Mac's own
 * `dns-sd -B`, etc.) discover instantly.
 *
 * The subprocess stays alive for the lifetime of the advertisement —
 * `dns-sd -R` blocks until killed, holding the registration. We
 * `child_process.spawn` it, capture its stdout for one-line
 * confirmation, and SIGTERM it on `stop()`.
 *
 * Platform gate: macOS only. On Linux / Windows the JS-core's
 * `multicast-dns` path actually works (no system-daemon conflict)
 * so callers stick with that there.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { platform } from "node:os";

export interface MdnsAdvertiserDarwinOptions {
  /** Bonjour service-instance name. Shown in NWBrowser as the peer. */
  deviceName: string;
  /** Service type — must match what consumers browse for. */
  serviceType: string; // e.g. "_dvai-bridge._tcp"
  /** Port the local server is listening on. */
  port: number;
  /**
   * TXT record key/value pairs. iOS NWBrowser parses these on the
   * fly; we use them to convey deviceId, dvaiVersion, etc.
   */
  txt: Record<string, string>;
  /** Override the dns-sd binary path for tests. */
  binaryPath?: string;
  /** Optional log sink — defaults to console.error so the Tauri
   *  shell forwards it to the dev tools. */
  log?: (level: "info" | "warn" | "error", msg: string) => void;
}

export class MdnsAdvertiserDarwin {
  private proc: ChildProcess | null = null;
  private readonly opts: MdnsAdvertiserDarwinOptions;

  constructor(opts: MdnsAdvertiserDarwinOptions) {
    this.opts = opts;
  }

  /** Returns true if running on macOS where dns-sd is reachable. */
  static isSupported(): boolean {
    return platform() === "darwin";
  }

  /**
   * Spawn `dns-sd -R …`. Non-blocking; the subprocess keeps the
   * registration alive until `stop()`. Idempotent — repeated
   * `start()` calls are a no-op.
   */
  start(): void {
    if (this.proc) return;
    if (!MdnsAdvertiserDarwin.isSupported()) {
      this.log("warn", "[mdns/darwin] start() called on non-macOS platform — ignoring");
      return;
    }

    // dns-sd -R "<name>" <type> <domain> <port> [key=value]...
    const args: string[] = [
      "-R",
      this.opts.deviceName,
      this.opts.serviceType,
      "local",
      String(this.opts.port),
    ];
    for (const [k, v] of Object.entries(this.opts.txt)) {
      args.push(`${k}=${v}`);
    }

    const bin = this.opts.binaryPath ?? "dns-sd";
    const proc = spawn(bin, args, {
      stdio: ["ignore", "pipe", "pipe"],
      // Detach from the controlling terminal so Ctrl+C in the dev
      // shell doesn't immediately propagate to dns-sd before we
      // can SIGTERM it cleanly.
      detached: false,
    });

    proc.on("error", (err) => {
      this.log("error", `[mdns/darwin] dns-sd spawn failed: ${String(err)}`);
    });
    proc.on("exit", (code, signal) => {
      this.log(
        "info",
        `[mdns/darwin] dns-sd exited code=${code} signal=${signal ?? "(none)"}`,
      );
      // Only clear if the proc reference is still ours (avoid
      // racing with a manual stop().
      if (this.proc === proc) this.proc = null;
    });
    proc.stdout?.on("data", (chunk: Buffer) => {
      // dns-sd prints one "Got a reply for service…" or "Registered"
      // line per registration. Surface the first one for diagnostics.
      const line = chunk.toString("utf8").trim().split("\n")[0];
      if (line) this.log("info", `[mdns/darwin] ${line}`);
    });
    proc.stderr?.on("data", (chunk: Buffer) => {
      const line = chunk.toString("utf8").trim();
      if (line) this.log("warn", `[mdns/darwin] (stderr) ${line}`);
    });

    this.proc = proc;
    this.log(
      "info",
      `[mdns/darwin] advertising "${this.opts.deviceName}" on ${this.opts.serviceType}:${this.opts.port}`,
    );
  }

  /**
   * Send SIGTERM to the dns-sd subprocess. Idempotent. The exit
   * handler clears the internal handle.
   */
  stop(): void {
    if (!this.proc) return;
    try {
      this.proc.kill("SIGTERM");
    } catch (err) {
      this.log("warn", `[mdns/darwin] kill failed: ${String(err)}`);
    }
    // Don't null out here — let the 'exit' handler do it so we
    // don't lose track of an orphaned proc.
  }

  private log(level: "info" | "warn" | "error", msg: string): void {
    if (this.opts.log) {
      this.opts.log(level, msg);
    } else if (level === "error") {
      console.error(msg);
    } else if (level === "warn") {
      console.warn(msg);
    } else {
      console.log(msg);
    }
  }
}
