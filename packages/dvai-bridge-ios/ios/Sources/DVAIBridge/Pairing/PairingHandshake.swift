import Foundation
import CryptoKit

/// Pairing-handshake primitives: HMAC-SHA256 signing of offload
/// requests + helpers to compose the canonical signed message. Mirrors
/// `packages/dvai-bridge-core/src/pairing/handshake.ts` byte-for-byte
/// so signatures round-trip between iOS and other peers (Node, Android,
/// browser).
///
/// All keys / nonces / signatures are encoded in URL-safe base64
/// without padding — same as the TS side's `encodeBase64Url`.
public enum PairingHandshake {

    // MARK: - Public API

    /// Generate a fresh 256-bit pairing key (base64-url, no padding).
    public static func generatePairingKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64UrlEncode(Data(bytes))
    }

    /// Generate a fresh nonce for a handshake request (16 bytes).
    public static func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64UrlEncode(Data(bytes))
    }

    /// HMAC-SHA256(pairingKey, message) → base64-url encoded.
    public static func signHmac(pairingKey: String, message: String) throws -> String {
        let keyData = try decodeBase64Url(pairingKey)
        let key = SymmetricKey(data: keyData)
        let messageData = Data(message.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: key)
        return base64UrlEncode(Data(mac))
    }

    /// Constant-time-ish HMAC verify. Returns true on match.
    public static func verifyHmac(
        pairingKey: String,
        message: String,
        signature: String
    ) throws -> Bool {
        let expected = try signHmac(pairingKey: pairingKey, message: message)
        return constantTimeEquals(expected, signature)
    }

    /// Compose the canonical message that gets HMAC-signed for a
    /// peer-to-peer offload request. Mirrors
    /// `composeSignedMessage` in handshake.ts:
    ///
    ///     `${nonce}\n${METHOD}\n${path}\n${bodyHash}`
    ///
    /// where bodyHash is the hex-encoded SHA-256 of the request body
    /// bytes (or all-zero hex for empty body).
    public static func composeSignedMessage(
        nonce: String,
        method: String,
        path: String,
        body: String?
    ) -> String {
        let bodyHash: String
        if let body = body, !body.isEmpty {
            bodyHash = sha256Hex(body)
        } else {
            bodyHash = String(repeating: "0", count: 64)
        }
        return "\(nonce)\n\(method.uppercased())\n\(path)\n\(bodyHash)"
    }

    /// Hex-encoded SHA-256 of the input string. Public for tests.
    public static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Base64-url helpers

    /// URL-safe base64 encode without padding. Public for tests.
    public static func base64UrlEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode URL-safe base64 (with or without padding). Public for tests.
    public static func decodeBase64Url(_ s: String) throws -> Data {
        var b64 = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - (b64.count % 4)) % 4
        b64 += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: b64) else {
            throw DVAIBridgeError.configurationInvalid(reason: "invalid base64-url string")
        }
        return data
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }
}

/// HandshakeRequest body the offload-source POSTs to the target's
/// `/v1/dvai/handshake` endpoint. Matches the TS shape.
public struct HandshakeRequest: Sendable, Equatable, Codable {
    public let originDeviceId: String
    public let originDeviceName: String
    public let originVersion: String
    public let nonce: String

    public init(originDeviceId: String, originDeviceName: String, originVersion: String, nonce: String) {
        self.originDeviceId = originDeviceId
        self.originDeviceName = originDeviceName
        self.originVersion = originVersion
        self.nonce = nonce
    }
}

/// HandshakeResponse the target returns. Matches the TS shape.
public struct HandshakeResponse: Sendable, Equatable, Codable {
    public let approved: Bool
    public let pairingKey: String?
    public let reason: String?

    public init(approved: Bool, pairingKey: String? = nil, reason: String? = nil) {
        self.approved = approved
        self.pairingKey = pairingKey
        self.reason = reason
    }
}
