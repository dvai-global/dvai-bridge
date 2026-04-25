// Internal/HttpServer.swift
import Foundation
import Telegraph

/// Wraps Telegraph's `Server` with port-fallback bind logic.
///
/// Telegraph 0.40 exposes a synchronous, throwing `start(port:interface:)`
/// and a synchronous `stop(immediately:)`. We wrap those in an `actor` so
/// concurrent callers see consistent state.
actor HttpServer {
    private var server: Server?
    private(set) var boundPort: Int?

    init() {}

    /// Try to bind to `basePort`, falling back to `basePort+1`, ..., up to
    /// `maxAttempts` ports. Returns the port that bound successfully.
    /// Throws if all ports in the range are unavailable.
    func tryBind(basePort: Int, maxAttempts: Int, host: String) async throws -> Int {
        let lastPort = basePort + maxAttempts - 1

        for i in 0..<maxAttempts {
            let port = basePort + i
            let s = Server()
            do {
                try s.start(port: port, interface: host)
                self.server = s
                self.boundPort = port
                return port
            } catch {
                // Most likely "address in use"; ensure partial state is cleaned
                // up and try the next port.
                s.stop(immediately: true)
                continue
            }
        }

        let msg = "[DVAI] Could not bind HTTP transport to any port in range " +
                  "\(basePort)..\(lastPort) (all in use). " +
                  "Another local AI server may already be running."
        throw NSError(
            domain: "DVAIBridgeLlama",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
    }

    /// Stops the server. Idempotent — safe to call multiple times,
    /// including before any successful bind.
    func stop() {
        if let s = server {
            s.stop(immediately: true)
            server = nil
            boundPort = nil
        }
    }
}
