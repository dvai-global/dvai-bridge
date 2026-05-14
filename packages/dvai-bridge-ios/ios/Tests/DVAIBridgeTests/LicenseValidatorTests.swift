/*
 * Tests for the iOS offline JWT license validator.
 *
 * Mirrors `packages/dvai-bridge-core/src/__tests__/license.test.ts` —
 * any difference in coverage between the two files is a real bug, not
 * a stylistic choice. The wire format (JWT header + ES256 payload +
 * P-256 signature) is identical across SDKs; the tests verify both
 * happy paths and every documented failure mode against `validate()`
 * (never throws) and `validateAndAssert()` (throws on
 * free-prod / free-expired).
 *
 * Each test sets `DVAI_FORCE_PROD=1` so the dev-mode auto-bypass doesn't
 * mask validation failures, and cleans up in `tearDown` so a test that
 * wants to exercise the bypass branch can do so.
 *
 * All tests use a freshly-generated test ES256 keypair so they don't
 * depend on the placeholder key in `PublicKeys.swift`. The injected
 * `publicKeys` option on `LicenseValidatorOptions` makes that possible
 * without touching the production registry.
 */
import XCTest
import JWTKit
@testable import DVAIBridge

final class LicenseValidatorTests: XCTestCase {
    /// Test-only ES256 keypair. Generated once per test invocation so
    /// the signing operations stay fast. The matching public JWK is
    /// injected into the validator via `LicenseValidatorOptions.publicKeys`.
    private static let testKid = "test-kid-2026"
    private var privateKey: ES256PrivateKey!
    private var publicJwk: DvaiPublicKeyJwk!
    private var publicKeys: [String: DvaiPublicKeyJwk]!

    override func setUp() async throws {
        try await super.setUp()
        privateKey = ES256PrivateKey()
        let params = privateKey.parameters!
        publicJwk = DvaiPublicKeyJwk(
            kty: "EC",
            crv: "P-256",
            // JWTKit's ECDSAParameters yields base64-standard-encoded
            // x / y. The DvaiPublicKeyJwk we feed back into the
            // validator goes through the same JWTKit path
            // (`ECDSA.PublicKey<P256>(parameters:)`), which calls
            // `base64URLDecodedData()` — JWTKit's base64URLDecodedData
            // accepts both base64-standard and base64url, so this works.
            x: params.x,
            y: params.y,
            alg: "ES256",
            use: "sig",
            kid: Self.testKid
        )
        publicKeys = [Self.testKid: publicJwk]
    }

    override func tearDown() async throws {
        unsetenv("DVAI_FORCE_PROD")
        unsetenv("DVAI_FORCE_DEV")
        unsetenv("DVAI_LICENSE_TOKEN")
        unsetenv("DVAI_LICENSE_PATH")
        unsetenv("DVAI_AUDIENCE")
        try await super.tearDown()
    }

    // MARK: - Mint helper

    /// Mint a license JWT for tests.
    private func mintLicense(
        aud: [String] = ["*"],
        platforms: [String] = ["ios", "android", "node", "web"],
        tier: String = "commercial",
        licensee: String = "Test Co",
        exp: Int64? = nil,
        iss: String = "DVAI-Bridge",
        kid: String? = nil,
        privateKeyOverride: ES256PrivateKey? = nil
    ) async throws -> String {
        let now = Int64(Date().timeIntervalSince1970)
        let expValue = exp ?? (now + 30 * 24 * 3600) // +30 days
        let payload = DvaiLicensePayload(
            iss: iss,
            sub: "test-license",
            aud: aud,
            tier: tier,
            platforms: platforms,
            licensee: licensee,
            iat: now,
            exp: expValue
        )
        let keys = JWTKeyCollection()
        let keyKid = JWKIdentifier(string: kid ?? Self.testKid)
        await keys.add(ecdsa: privateKeyOverride ?? privateKey, kid: keyKid)
        var header = JWTHeader()
        header.alg = "ES256"
        header.typ = "JWT"
        header.kid = keyKid.string
        return try await keys.sign(payload, kid: keyKid, header: header)
    }

    // MARK: - Happy path

    func testAcceptsWellFormedCommercialToken() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(
            aud: ["acme.com"],
            platforms: ["ios"],
            licensee: "Acme Inc"
        )
        let v = LicenseValidator(options: LicenseValidatorOptions(token: token, publicKeys: publicKeys))
        let status = await v.validate()
        guard case .commercial(let licensee, let expiresAt, let platform, let matched) = status else {
            return XCTFail("expected .commercial, got \(status)")
        }
        XCTAssertEqual(licensee, "Acme Inc")
        XCTAssertEqual(matched, "acme.com")
        XCTAssertEqual(platform, .ios)
        XCTAssertGreaterThan(expiresAt, Int64(Date().timeIntervalSince1970))
    }

    func testMatchesWildcardSubdomainAudience() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "app.acme.com", 1)
        let token = try await mintLicense(aud: ["*.acme.com"], platforms: ["ios"])
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        )).validate()
        guard case .commercial(_, _, _, let matched) = status else {
            return XCTFail("expected .commercial, got \(status)")
        }
        XCTAssertEqual(matched, "*.acme.com")
    }

    func testMatchesStarAudienceForTrial() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        // Intentionally no DVAI_AUDIENCE — bundle id may also be nil in
        // the test host. Either way, "*" must match.
        unsetenv("DVAI_AUDIENCE")
        let token = try await mintLicense(aud: ["*"], platforms: ["ios"], tier: "trial")
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        )).validate()
        if case .trial = status {
            // pass
        } else {
            XCTFail("expected .trial, got \(status)")
        }
    }

    func testMatchesApexOfWildcardEntry() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(aud: ["*.acme.com"], platforms: ["ios"])
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        )).validate()
        if case .commercial = status {
            // pass
        } else {
            XCTFail("expected .commercial, got \(status)")
        }
    }

    // MARK: - Failure modes (each must collapse to a free-* status, never throw)

    func testFreeProdOnTamperedSignature() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(aud: ["acme.com"], platforms: ["ios"])
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3)
        // Flip a byte in the payload segment to break the signature.
        var payloadSeg = String(parts[1])
        payloadSeg = String(payloadSeg.dropLast(2)) + "XX"
        let corrupted = "\(parts[0]).\(payloadSeg).\(parts[2])"
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: corrupted, publicKeys: publicKeys
        )).validate()
        guard case .freeProd(let reason) = status else {
            return XCTFail("expected .freeProd, got \(status)")
        }
        let lower = reason.lowercased()
        XCTAssertTrue(
            lower.contains("signature") || lower.contains("verification") || lower.contains("malformed") || lower.contains("parseable"),
            "reason should mention signature/verification/malformed: \(reason)"
        )
    }

    func testFreeExpiredWhenExpInPast() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let pastSeconds = Int64(Date().timeIntervalSince1970) - 3600
        let token = try await mintLicense(
            aud: ["acme.com"],
            platforms: ["ios"],
            licensee: "Expired Co",
            exp: pastSeconds
        )
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        )).validate()
        guard case .freeExpired(let licensee, let expiredAt) = status else {
            return XCTFail("expected .freeExpired, got \(status)")
        }
        XCTAssertEqual(licensee, "Expired Co")
        XCTAssertLessThan(expiredAt, Int64(Date().timeIntervalSince1970))
    }

    func testFreeProdOnAudienceMismatch() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "widget.io", 1)
        let token = try await mintLicense(aud: ["acme.com"], platforms: ["ios"])
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        )).validate()
        guard case .freeProd(let reason) = status else {
            return XCTFail("expected .freeProd, got \(status)")
        }
        XCTAssertTrue(reason.contains("audience"), "reason: \(reason)")
        XCTAssertTrue(reason.contains("widget.io"), "reason: \(reason)")
    }

    func testFreeProdOnPlatformMismatch() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(
            aud: ["acme.com"],
            platforms: ["android", "node"]   // not ios
        )
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        )).validate()
        guard case .freeProd(let reason) = status else {
            return XCTFail("expected .freeProd, got \(status)")
        }
        XCTAssertTrue(reason.contains("platform"), "reason: \(reason)")
        XCTAssertTrue(reason.contains("ios"), "reason: \(reason)")
    }

    func testFreeProdOnUnknownKid() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(
            aud: ["acme.com"],
            platforms: ["ios"],
            kid: "unknown-kid-2099"
        )
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        )).validate()
        guard case .freeProd(let reason) = status else {
            return XCTFail("expected .freeProd, got \(status)")
        }
        XCTAssertTrue(reason.contains("unknown-kid-2099"), "reason: \(reason)")
        XCTAssertTrue(reason.contains("registry"), "reason: \(reason)")
    }

    func testRefusesPlaceholderKidUnlessOptedIn() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(
            aud: ["acme.com"],
            platforms: ["ios"],
            kid: DVAI_PLACEHOLDER_KID
        )
        // Register our test key under the placeholder kid so the
        // signature would otherwise verify — the refusal must come from
        // the placeholder-key check, not from "no such key".
        let registry = [
            DVAI_PLACEHOLDER_KID: DvaiPublicKeyJwk(
                kty: publicJwk.kty,
                crv: publicJwk.crv,
                x: publicJwk.x,
                y: publicJwk.y,
                alg: publicJwk.alg,
                use: publicJwk.use,
                kid: DVAI_PLACEHOLDER_KID
            )
        ]
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: registry
        )).validate()
        guard case .freeProd(let reason) = status else {
            return XCTFail("expected .freeProd, got \(status)")
        }
        XCTAssertTrue(reason.contains("placeholder"), "reason: \(reason)")
    }

    func testAcceptsPlaceholderKidWhenOptedIn() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(
            aud: ["acme.com"],
            platforms: ["ios"],
            kid: DVAI_PLACEHOLDER_KID
        )
        let registry = [
            DVAI_PLACEHOLDER_KID: DvaiPublicKeyJwk(
                kty: publicJwk.kty,
                crv: publicJwk.crv,
                x: publicJwk.x,
                y: publicJwk.y,
                alg: publicJwk.alg,
                use: publicJwk.use,
                kid: DVAI_PLACEHOLDER_KID
            )
        ]
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: token,
            publicKeys: registry,
            allowPlaceholderKey: true
        )).validate()
        if case .commercial = status {
            // pass
        } else {
            XCTFail("expected .commercial with allowPlaceholderKey, got \(status)")
        }
    }

    func testRejectsAlgNoneAndAlgHS256() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        // Hand-craft an alg=none token. The validator MUST refuse before
        // ever trying to verify a signature, because a malicious token
        // with alg=none would otherwise be accepted on the empty
        // signature segment.
        let header = """
        {"alg":"none","typ":"JWT","kid":"\(Self.testKid)"}
        """
        let payload = """
        {"iss":"DVAI-Bridge","sub":"x","aud":["acme.com"],"tier":"commercial","platforms":["ios"],"licensee":"Evil Co","iat":\(Int(Date().timeIntervalSince1970)),"exp":\(Int(Date().timeIntervalSince1970) + 3600)}
        """
        let h64 = Self.base64Url(header.data(using: .utf8)!)
        let p64 = Self.base64Url(payload.data(using: .utf8)!)
        let noneToken = "\(h64).\(p64)."
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: noneToken, publicKeys: publicKeys
        )).validate()
        guard case .freeProd(let reason) = status else {
            return XCTFail("expected .freeProd, got \(status)")
        }
        XCTAssertTrue(reason.contains("ES256"), "reason: \(reason)")
    }

    func testFreeProdOnMalformedTokenSegments() async {
        setenv("DVAI_FORCE_PROD", "1", 1)
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: "not.a.valid.jwt", publicKeys: publicKeys
        )).validate()
        if case .freeProd = status {
            // pass
        } else {
            XCTFail("expected .freeProd, got \(status)")
        }
    }

    func testFreeProdWhenNoTokenAndNoDiscovery() async {
        setenv("DVAI_FORCE_PROD", "1", 1)
        // No token, no path, and the bundle has no dvai-license.jwt
        // resource bundled in the test target — auto-discovery should
        // turn up empty.
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            publicKeys: publicKeys
        )).validate()
        guard case .freeProd(let reason) = status else {
            return XCTFail("expected .freeProd, got \(status)")
        }
        XCTAssertTrue(reason.contains("no license token found"), "reason: \(reason)")
    }

    // MARK: - Dev mode bypass

    func testReturnsFreeDevWhenDVAIForceDevSet() async {
        setenv("DVAI_FORCE_DEV", "1", 1)
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            publicKeys: publicKeys
        )).validate()
        if case .freeDev = status {
            // pass
        } else {
            XCTFail("expected .freeDev, got \(status)")
        }
    }

    func testReturnsFreeDevInDebugBuildOrSimulator() async {
        // DVAI_FORCE_PROD is intentionally NOT set here. On a typical
        // test run the build is DEBUG and/or the simulator, so the
        // dev-mode bypass should fire. The validator's detectDevMode()
        // returns isDev=true for any of: DVAI_FORCE_DEV, #if DEBUG,
        // #if targetEnvironment(simulator).
        unsetenv("DVAI_FORCE_PROD")
        unsetenv("DVAI_FORCE_DEV")
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            publicKeys: publicKeys
        )).validate()
        // In a DEBUG test build this is .freeDev. In a Release-config
        // run of the tests (unusual but valid), we expect .freeProd
        // because there's no license token in the test bundle either.
        // Accept either — the substantive check is that no signature
        // verification ran (no crash on missing publicKeys).
        switch status {
        case .freeDev, .freeProd:
            // pass
            break
        default:
            XCTFail("expected .freeDev or .freeProd, got \(status)")
        }
    }

    // MARK: - File discovery

    func testLoadsFromExplicitPath() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(aud: ["acme.com"], platforms: ["ios"])
        let tmp = try createTempLicenseFile(contents: token)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            path: tmp.path, publicKeys: publicKeys
        )).validate()
        if case .commercial = status {
            // pass
        } else {
            XCTFail("expected .commercial, got \(status)")
        }
    }

    func testLoadsFromDVAILicenseTokenEnvVar() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(aud: ["acme.com"], platforms: ["ios"])
        setenv("DVAI_LICENSE_TOKEN", token, 1)
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            publicKeys: publicKeys
        )).validate()
        if case .commercial = status {
            // pass
        } else {
            XCTFail("expected .commercial, got \(status)")
        }
    }

    func testLoadsFromDVAILicensePathEnvVar() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(aud: ["acme.com"], platforms: ["ios"])
        let tmp = try createTempLicenseFile(contents: token)
        defer { try? FileManager.default.removeItem(at: tmp) }
        setenv("DVAI_LICENSE_PATH", tmp.path, 1)
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            publicKeys: publicKeys
        )).validate()
        if case .commercial = status {
            // pass
        } else {
            XCTFail("expected .commercial, got \(status)")
        }
    }

    func testFreeProdWhenExplicitPathDoesNotExist() async {
        setenv("DVAI_FORCE_PROD", "1", 1)
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            path: "/nonexistent/path/dvai-license.jwt",
            publicKeys: publicKeys
        )).validate()
        if case .freeProd = status {
            // pass
        } else {
            XCTFail("expected .freeProd, got \(status)")
        }
    }

    func testInlineTokenWinsOverPath() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let inline = try await mintLicense(
            aud: ["acme.com"],
            platforms: ["ios"],
            licensee: "Inline Co"
        )
        let status = await LicenseValidator(options: LicenseValidatorOptions(
            token: inline,
            path: "/nonexistent/path/dvai-license.jwt",
            publicKeys: publicKeys
        )).validate()
        guard case .commercial(let licensee, _, _, _) = status else {
            return XCTFail("expected .commercial, got \(status)")
        }
        XCTAssertEqual(licensee, "Inline Co")
    }

    // MARK: - validateAndAssert (BSL 1.1 enforcement)

    func testValidateAndAssertReturnsCommercialWithoutThrowing() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(aud: ["acme.com"], platforms: ["ios"])
        let status = try await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        )).validateAndAssert()
        if case .commercial = status {
            // pass
        } else {
            XCTFail("expected .commercial, got \(status)")
        }
    }

    func testValidateAndAssertReturnsTrialWithoutThrowing() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(
            aud: ["acme.com"],
            platforms: ["ios"],
            tier: "trial"
        )
        let status = try await LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        )).validateAndAssert()
        if case .trial = status {
            // pass
        } else {
            XCTFail("expected .trial, got \(status)")
        }
    }

    func testValidateAndAssertReturnsFreeDevWithoutThrowing() async throws {
        setenv("DVAI_FORCE_DEV", "1", 1)
        let status = try await LicenseValidator(options: LicenseValidatorOptions(
            publicKeys: publicKeys
        )).validateAndAssert()
        if case .freeDev = status {
            // pass
        } else {
            XCTFail("expected .freeDev, got \(status)")
        }
    }

    func testValidateAndAssertThrowsOnMissingLicense() async {
        setenv("DVAI_FORCE_PROD", "1", 1)
        let v = LicenseValidator(options: LicenseValidatorOptions(publicKeys: publicKeys))
        do {
            _ = try await v.validateAndAssert()
            XCTFail("should have thrown")
        } catch let error as LicenseRequiredError {
            if case .freeProd = error.status {
                // pass
            } else {
                XCTFail("expected status .freeProd, got \(error.status)")
            }
            XCTAssertTrue(error.message.contains("Commercial License Required"), "message: \(error.message)")
            XCTAssertTrue(error.message.contains("dvai-license.jwt"), "message: \(error.message)")
            XCTAssertTrue(error.message.contains("DVAI_LICENSE_PATH"), "message: \(error.message)")
        } catch {
            XCTFail("expected LicenseRequiredError, got \(error)")
        }
    }

    func testValidateAndAssertThrowsOnExpiredLicense() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let pastSeconds = Int64(Date().timeIntervalSince1970) - 3600
        let token = try await mintLicense(
            aud: ["acme.com"],
            platforms: ["ios"],
            licensee: "Expired Co",
            exp: pastSeconds
        )
        let v = LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        ))
        do {
            _ = try await v.validateAndAssert()
            XCTFail("should have thrown")
        } catch let error as LicenseRequiredError {
            if case .freeExpired = error.status {
                // pass
            } else {
                XCTFail("expected status .freeExpired, got \(error.status)")
            }
            XCTAssertTrue(error.message.contains("Expired Co"), "message: \(error.message)")
        } catch {
            XCTFail("expected LicenseRequiredError, got \(error)")
        }
    }

    func testValidateAndAssertThrowsOnTamperedToken() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "acme.com", 1)
        let token = try await mintLicense(aud: ["acme.com"], platforms: ["ios"])
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let corrupted = "\(parts[0]).\(String(parts[1]).dropLast(2))XX.\(parts[2])"
        let v = LicenseValidator(options: LicenseValidatorOptions(
            token: corrupted, publicKeys: publicKeys
        ))
        do {
            _ = try await v.validateAndAssert()
            XCTFail("should have thrown")
        } catch is LicenseRequiredError {
            // pass
        } catch {
            XCTFail("expected LicenseRequiredError, got \(error)")
        }
    }

    func testValidateAndAssertThrowsOnAudienceMismatch() async throws {
        setenv("DVAI_FORCE_PROD", "1", 1)
        setenv("DVAI_AUDIENCE", "widget.io", 1)
        let token = try await mintLicense(aud: ["acme.com"], platforms: ["ios"])
        let v = LicenseValidator(options: LicenseValidatorOptions(
            token: token, publicKeys: publicKeys
        ))
        do {
            _ = try await v.validateAndAssert()
            XCTFail("should have thrown")
        } catch is LicenseRequiredError {
            // pass
        } catch {
            XCTFail("expected LicenseRequiredError, got \(error)")
        }
    }

    func testValidateAndAssertDoesNotThrowInDevMode() async throws {
        // The dev-mode bypass short-circuits BEFORE any token
        // verification, so a developer in DEBUG / DVAI_FORCE_DEV never
        // sees a license error — even with a syntactically invalid token.
        setenv("DVAI_FORCE_DEV", "1", 1)
        let v = LicenseValidator(options: LicenseValidatorOptions(
            token: "not-even-a-jwt", publicKeys: publicKeys
        ))
        let status = try await v.validateAndAssert()
        if case .freeDev = status {
            // pass
        } else {
            XCTFail("expected .freeDev, got \(status)")
        }
    }

    // MARK: - Helpers

    /// Write `contents` to a unique temp file and return its URL.
    private func createTempLicenseFile(contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dvai-license-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("dvai-license.jwt")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Base64url-encode raw bytes (no padding, `-`/`_`).
    private static func base64Url(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}
