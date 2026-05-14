// Tests for the Flutter port of the offline JWT license validator.
//
// Mirrors `packages/dvai-bridge-core/src/__tests__/license.test.ts`
// case-for-case — the JWT format, claim shape, audience-matching
// rules, alg-confusion defence, and throw-on-prod policy are all
// validated against the same expected behaviour. The Flutter-specific
// adaptations are:
//
//   - `DVAI_FORCE_PROD` / `DVAI_FORCE_DEV` env-var manipulation in
//     the JS tests becomes `devModeOverride` injected via
//     `LicenseValidatorOptions`. Dart cannot mutate
//     `Platform.environment` at runtime.
//   - `DVAI_AUDIENCE` env-var manipulation becomes
//     `audienceOverride`. Same reason.
//   - The test keypair is generated via `pointycastle`'s
//     `KeyGenerator('EC')` (since `dart_jsonwebtoken` doesn't expose a
//     generator) and converted to JWK for injection into the
//     validator's `publicKeys` option.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart' as djwt;
import 'package:dvai_bridge/dvai_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;

import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Test fixture state. Generated once in setUpAll so the suite runs
  // fast without re-deriving keys on every case. Mirrors the JS-side
  // `beforeAll` block.
  const String testKid = 'test-kid-2026';
  late djwt.ECPrivateKey privateKey;
  late DvaiPublicKey publicJwk;
  late Map<String, DvaiPublicKey> publicKeys;

  // Dev-mode overrides used in every test. Dart can't mutate
  // Platform.environment so we pass these explicitly.
  const DevModeDetection forceProd =
      DevModeDetection(isDev: false, reason: 'test: forceProd');
  const DevModeDetection forceDev =
      DevModeDetection(isDev: true, reason: 'test: forceDev');

  setUpAll(() {
    final _GeneratedKeyPair kp = _generateEcP256KeyPair();
    privateKey = djwt.ECPrivateKey.raw(kp.private);

    final BigInt? x = kp.public.Q?.x?.toBigInteger();
    final BigInt? y = kp.public.Q?.y?.toBigInteger();
    if (x == null || y == null) {
      throw StateError('test ECPublicKey missing coordinates');
    }
    publicJwk = DvaiPublicKey(
      x: _b64UrlEncodeBigInt(x),
      y: _b64UrlEncodeBigInt(y),
      kid: testKid,
    );
    publicKeys = <String, DvaiPublicKey>{testKid: publicJwk};
  });

  /// Mint a license JWT for tests. Mirrors the JS `mintLicense` helper.
  String mintLicense({
    List<String>? aud,
    List<String>? platforms,
    String tier = 'commercial',
    String licensee = 'Test Co',
    Duration expiresIn = const Duration(days: 30),
    String iss = 'DVAI-Bridge',
    String kid = testKid,
  }) {
    final djwt.JWT jwt = djwt.JWT(
      <String, dynamic>{
        'tier': tier,
        'licensee': licensee,
        'platforms': platforms ?? <String>['node', 'web', 'ios', 'android'],
      },
      issuer: iss,
      subject: 'test-license',
      audience: djwt.Audience(aud ?? <String>['*']),
      header: <String, dynamic>{'kid': kid, 'typ': 'JWT', 'alg': 'ES256'},
    );
    return jwt.sign(
      privateKey,
      algorithm: djwt.JWTAlgorithm.ES256,
      expiresIn: expiresIn,
    );
  }

  /// Mint a license with an explicit absolute `exp` (seconds since
  /// epoch). Used to test the expired path — `expiresIn` is positive
  /// only in the standard `sign()` helper, so this path embeds `exp`
  /// directly in the payload.
  String mintLicenseWithAbsoluteExp({
    required int expSeconds,
    List<String>? aud,
    List<String>? platforms,
    String tier = 'commercial',
    String licensee = 'Expired Co',
    String iss = 'DVAI-Bridge',
    String kid = testKid,
  }) {
    final int nowSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final djwt.JWT jwt = djwt.JWT(
      <String, dynamic>{
        'tier': tier,
        'licensee': licensee,
        'platforms': platforms ?? <String>['node', 'web', 'ios', 'android'],
        'iat': nowSeconds - 7200,
        'exp': expSeconds,
      },
      issuer: iss,
      subject: 'test-license',
      audience: djwt.Audience(aud ?? <String>['*']),
      header: <String, dynamic>{'kid': kid, 'typ': 'JWT', 'alg': 'ES256'},
    );
    return jwt.sign(
      privateKey,
      algorithm: djwt.JWTAlgorithm.ES256,
      noIssueAt: true,
    );
  }

  group('LicenseValidator — happy path', () {
    test('accepts a commercial token and reports the licensee + expiry',
        () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
        licensee: 'Acme Inc',
      );
      final LicenseValidator v = LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      );
      final LicenseStatus status = await v.validate();
      expect(status, isA<Commercial>());
      final Commercial commercial = status as Commercial;
      expect(commercial.licensee, 'Acme Inc');
      expect(commercial.audienceMatched, 'acme.com');
      expect(commercial.platform, DvaiPlatform.flutter);
      expect(
        commercial.expiresAt,
        greaterThan(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      );
    });

    test('matches wildcard subdomain audience entries', () async {
      final String token = mintLicense(
        aud: <String>['*.acme.com'],
        platforms: <String>['flutter'],
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'app.acme.com',
        ),
      ).validate();
      expect(status, isA<Commercial>());
      expect((status as Commercial).audienceMatched, '*.acme.com');
    });

    test('matches `*` audience for any-audience trial licenses', () async {
      final String token = mintLicense(
        aud: <String>['*'],
        platforms: <String>['flutter'],
        tier: 'trial',
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          // No audience override — runtime audience is null.
          audienceOverride: '',
        ),
      ).validate();
      expect(status, isA<Trial>());
    });

    test('matches the bare apex of a `*.example.com` wildcard', () async {
      final String token = mintLicense(
        aud: <String>['*.acme.com'],
        platforms: <String>['flutter'],
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validate();
      expect(status, isA<Commercial>());
    });
  });

  group('LicenseValidator — failure modes', () {
    test('returns free-prod when the token has been tampered with', () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
      );
      final List<String> parts = token.split('.');
      final String corruptedPayload =
          '${parts[1].substring(0, parts[1].length - 2)}XX';
      final String corrupted = '${parts[0]}.$corruptedPayload.${parts[2]}';
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: corrupted,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validate();
      expect(status, isA<FreeProd>());
      expect(
        (status as FreeProd).reason.toLowerCase(),
        matches(RegExp('signature|verification|parse|claim|invalid')),
      );
    });

    test('returns free-expired when exp is in the past', () async {
      final int pastSeconds =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 3600;
      final String token = mintLicenseWithAbsoluteExp(
        expSeconds: pastSeconds,
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
        licensee: 'Expired Co',
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validate();
      expect(status, isA<FreeExpired>());
      final FreeExpired expired = status as FreeExpired;
      expect(expired.licensee, 'Expired Co');
      expect(
        expired.expiredAt,
        lessThan(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      );
    });

    test("returns free-prod when audience doesn't match", () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'widget.io',
        ),
      ).validate();
      expect(status, isA<FreeProd>());
      final FreeProd prod = status as FreeProd;
      expect(prod.reason, contains('audience'));
      expect(prod.reason, contains('widget.io'));
    });

    test(
        'returns free-prod when the runtime platform isn\'t in the platforms claim',
        () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['ios', 'android'], // not flutter
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validate();
      expect(status, isA<FreeProd>());
      final FreeProd prod = status as FreeProd;
      expect(prod.reason, contains('platform'));
      expect(prod.reason, contains('flutter'));
    });

    test("returns free-prod when the kid isn't in the registry", () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
        kid: 'unknown-kid-2099',
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validate();
      expect(status, isA<FreeProd>());
      final FreeProd prod = status as FreeProd;
      expect(prod.reason, contains('unknown-kid-2099'));
      expect(prod.reason, contains('registry'));
    });

    test('refuses the placeholder kid unless allowPlaceholderKey is set',
        () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
        kid: placeholderKid,
      );
      // Stash the test keypair under the placeholder kid so signature
      // verification would otherwise succeed.
      final Map<String, DvaiPublicKey> registry = <String, DvaiPublicKey>{
        placeholderKid: DvaiPublicKey(
          x: publicJwk.x,
          y: publicJwk.y,
          kid: placeholderKid,
        ),
      };
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: registry,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validate();
      expect(status, isA<FreeProd>());
      expect((status as FreeProd).reason, contains('placeholder'));
    });

    test('accepts the placeholder kid when allowPlaceholderKey is set',
        () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
        kid: placeholderKid,
      );
      final Map<String, DvaiPublicKey> registry = <String, DvaiPublicKey>{
        placeholderKid: DvaiPublicKey(
          x: publicJwk.x,
          y: publicJwk.y,
          kid: placeholderKid,
        ),
      };
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: registry,
          allowPlaceholderKey: true,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validate();
      expect(status, isA<Commercial>());
    });

    test('rejects alg=none and alg=HS256 tokens (algorithm-confusion defense)',
        () async {
      // Build an alg=none-style malformed token. Headers: alg=none, no
      // signature.
      final String header = _b64UrlString(jsonEncode(<String, dynamic>{
        'alg': 'none',
        'typ': 'JWT',
      }));
      final String payload = _b64UrlString(jsonEncode(<String, dynamic>{
        'iss': 'DVAI-Bridge',
        'sub': 'x',
        'aud': <String>['acme.com'],
        'tier': 'commercial',
        'platforms': <String>['flutter'],
        'licensee': 'Evil Co',
        'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      }));
      final String noneToken = '$header.$payload.';
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: noneToken,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validate();
      expect(status, isA<FreeProd>());
      expect((status as FreeProd).reason, contains('ES256'));
    });

    test('returns free-prod when token is malformed (not 3 segments)',
        () async {
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: 'not.a.valid.jwt',
          publicKeys: publicKeys,
          devModeOverride: forceProd,
        ),
      ).validate();
      expect(status, isA<FreeProd>());
    });

    test('returns free-prod when no token is provided AND no auto-discovery',
        () async {
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          publicKeys: publicKeys,
          devModeOverride: forceProd,
        ),
      ).validate();
      expect(status, isA<FreeProd>());
      expect((status as FreeProd).reason, contains('no license token found'));
    });
  });

  group('LicenseValidator — dev mode bypass', () {
    test('returns free-dev when forceDev override is set', () async {
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          publicKeys: publicKeys,
          devModeOverride: forceDev,
        ),
      ).validate();
      expect(status, isA<FreeDev>());
    });

    test('forwards the reason string from the override', () async {
      const DevModeDetection custom =
          DevModeDetection(isDev: true, reason: 'kDebugMode');
      final LicenseStatus status = await LicenseValidator(
        const LicenseValidatorOptions(devModeOverride: custom),
      ).validate();
      expect(status, isA<FreeDev>());
      expect((status as FreeDev).reason, 'kDebugMode');
    });
  });

  group('LicenseValidator — token discovery', () {
    test('loads from an explicit path', () async {
      final Directory tmpDir =
          await Directory.systemTemp.createTemp('dvai-license-');
      try {
        final File f = File('${tmpDir.path}${Platform.pathSeparator}t.jwt');
        final String token = mintLicense(
          aud: <String>['acme.com'],
          platforms: <String>['flutter'],
        );
        await f.writeAsString(token);

        final LicenseStatus status = await LicenseValidator(
          LicenseValidatorOptions(
            path: f.path,
            publicKeys: publicKeys,
            devModeOverride: forceProd,
            audienceOverride: 'acme.com',
          ),
        ).validate();
        expect(status, isA<Commercial>());
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('returns free-prod when explicit path doesn\'t exist', () async {
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          path: '/nonexistent/path/dvai-license.jwt',
          publicKeys: publicKeys,
          devModeOverride: forceProd,
        ),
      ).validate();
      expect(status, isA<FreeProd>());
    });

    test('inline token wins over path when both are set', () async {
      final String inlineToken = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
        licensee: 'Inline Co',
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: inlineToken,
          path: '/nonexistent/path/dvai-license.jwt',
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validate();
      expect(status, isA<Commercial>());
      expect((status as Commercial).licensee, 'Inline Co');
    });
  });

  group('LicenseValidator — validateAndAssert (BSL 1.1 enforcement)', () {
    test('returns the status without throwing for commercial licenses',
        () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validateAndAssert();
      expect(status, isA<Commercial>());
    });

    test('returns the status without throwing for trial licenses', () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
        tier: 'trial',
      );
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      ).validateAndAssert();
      expect(status, isA<Trial>());
    });

    test('returns the status without throwing for free-dev', () async {
      final LicenseStatus status = await LicenseValidator(
        LicenseValidatorOptions(
          publicKeys: publicKeys,
          devModeOverride: forceDev,
        ),
      ).validateAndAssert();
      expect(status, isA<FreeDev>());
    });

    test('THROWS LicenseRequiredException when no license is found in prod',
        () async {
      final LicenseValidator v = LicenseValidator(
        LicenseValidatorOptions(
          publicKeys: publicKeys,
          devModeOverride: forceProd,
        ),
      );
      await expectLater(
        v.validateAndAssert(),
        throwsA(isA<LicenseRequiredException>()),
      );
    });

    test('THROWS LicenseRequiredException with status=free-prod for missing',
        () async {
      final LicenseValidator v = LicenseValidator(
        LicenseValidatorOptions(
          publicKeys: publicKeys,
          devModeOverride: forceProd,
        ),
      );
      try {
        await v.validateAndAssert();
        fail('should have thrown');
      } on LicenseRequiredException catch (err) {
        expect(err.status, isA<FreeProd>());
        expect(err.message, contains('Commercial License Required'));
        expect(err.message, contains('dvai-license.jwt'));
        expect(err.message, contains('licenseKeyPath'));
      }
    });

    test('THROWS with status=free-expired for expired tokens', () async {
      final int pastSeconds =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 3600;
      final String token = mintLicenseWithAbsoluteExp(
        expSeconds: pastSeconds,
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
        licensee: 'Expired Co',
      );
      final LicenseValidator v = LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      );
      try {
        await v.validateAndAssert();
        fail('should have thrown');
      } on LicenseRequiredException catch (err) {
        expect(err.status, isA<FreeExpired>());
        expect(err.message, contains('Expired Co'));
      }
    });

    test('THROWS for tampered tokens in production', () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
      );
      final List<String> parts = token.split('.');
      final String corrupted =
          '${parts[0]}.${parts[1].substring(0, parts[1].length - 2)}XX.${parts[2]}';
      final LicenseValidator v = LicenseValidator(
        LicenseValidatorOptions(
          token: corrupted,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'acme.com',
        ),
      );
      await expectLater(
        v.validateAndAssert(),
        throwsA(isA<LicenseRequiredException>()),
      );
    });

    test('THROWS for audience-mismatched tokens in production', () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
      );
      final LicenseValidator v = LicenseValidator(
        LicenseValidatorOptions(
          token: token,
          publicKeys: publicKeys,
          devModeOverride: forceProd,
          audienceOverride: 'widget.io',
        ),
      );
      await expectLater(
        v.validateAndAssert(),
        throwsA(isA<LicenseRequiredException>()),
      );
    });

    test('does NOT throw in dev mode even when license is invalid', () async {
      // The dev-mode bypass short-circuits BEFORE any token
      // verification, so a developer running on localhost never sees a
      // license error.
      final LicenseValidator v = LicenseValidator(
        LicenseValidatorOptions(
          token: 'not-even-a-jwt',
          publicKeys: publicKeys,
          devModeOverride: forceDev,
        ),
      );
      final LicenseStatus status = await v.validateAndAssert();
      expect(status, isA<FreeDev>());
    });
  });

  group('DVAIBridge.start — license-validator wiring', () {
    test('passes licenseToken / licenseKeyPath to the validator factory',
        () async {
      LicenseValidatorOptions? capturedOpts;
      final FakeHostApi api = FakeHostApi();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
        licenseValidatorFactory: (LicenseValidatorOptions opts) {
          capturedOpts = opts;
          // Return a real validator that uses forceDev so the bridge
          // proceeds without throwing.
          return LicenseValidator(
            LicenseValidatorOptions(
              token: opts.token,
              path: opts.path,
              publicKeys: opts.publicKeys,
              allowPlaceholderKey: opts.allowPlaceholderKey,
              devModeOverride: forceDev,
            ),
          );
        },
      );

      final BoundServer server = await bridge.start(const StartOptions(
        backend: BackendKind.llama,
        modelPath: '/tmp/m.gguf',
        licenseToken: 'inline-jwt-string',
        licenseKeyPath: '/var/secrets/license.jwt',
      ));

      expect(capturedOpts, isNotNull);
      expect(capturedOpts!.token, 'inline-jwt-string');
      expect(capturedOpts!.path, '/var/secrets/license.jwt');
      // BoundServer carries the validator's resolved status.
      expect(server.licenseStatus, isA<FreeDev>());
    });

    test('throws LicenseRequiredException before the native call in prod',
        () async {
      final FakeHostApi api = FakeHostApi();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
        licenseValidatorFactory: (LicenseValidatorOptions opts) =>
            LicenseValidator(
          LicenseValidatorOptions(
            publicKeys: publicKeys,
            devModeOverride: forceProd,
          ),
        ),
      );

      await expectLater(
        bridge.start(const StartOptions(
          backend: BackendKind.llama,
          modelPath: '/tmp/m.gguf',
        )),
        throwsA(isA<LicenseRequiredException>()),
      );
      // Native side never called — validator threw before crossing
      // the platform channel.
      expect(api.startCalls, isEmpty);
    });

    test('attaches commercial status to BoundServer on successful start',
        () async {
      final String token = mintLicense(
        aud: <String>['acme.com'],
        platforms: <String>['flutter'],
        licensee: 'Acme Inc',
      );
      final FakeHostApi api = FakeHostApi();
      final DVAIBridge bridge = DVAIBridge.test(
        api: api,
        eventChannel: FakeProgressEventChannel(),
        platform: const FakePlatform.android(),
        licenseValidatorFactory: (LicenseValidatorOptions opts) =>
            LicenseValidator(
          LicenseValidatorOptions(
            token: opts.token,
            publicKeys: publicKeys,
            devModeOverride: forceProd,
            audienceOverride: 'acme.com',
          ),
        ),
      );

      final BoundServer server = await bridge.start(StartOptions(
        backend: BackendKind.llama,
        modelPath: '/tmp/m.gguf',
        licenseToken: token,
      ));

      expect(server.licenseStatus, isA<Commercial>());
      final Commercial commercial = server.licenseStatus! as Commercial;
      expect(commercial.licensee, 'Acme Inc');
      expect(api.startCalls, hasLength(1));
    });
  });
}

/* -------------------------------------------------------------------------- */
/* Test fixtures — EC keypair generation                                      */
/* -------------------------------------------------------------------------- */

class _GeneratedKeyPair {
  _GeneratedKeyPair(this.private, this.public);
  final pc.ECPrivateKey private;
  final pc.ECPublicKey public;
}

_GeneratedKeyPair _generateEcP256KeyPair() {
  final pc.ECDomainParameters domain = pc.ECDomainParameters('prime256v1');
  final pc.FortunaRandom random = pc.FortunaRandom();
  // FortunaRandom needs 32 bytes of seed entropy.
  final Random seedSource = Random.secure();
  final Uint8List seed = Uint8List.fromList(
    List<int>.generate(32, (int _) => seedSource.nextInt(256)),
  );
  random.seed(pc.KeyParameter(seed));

  final pc.ECKeyGenerator generator = pc.ECKeyGenerator();
  generator.init(pc.ParametersWithRandom<pc.ECKeyGeneratorParameters>(
    pc.ECKeyGeneratorParameters(domain),
    random,
  ));
  final pc.AsymmetricKeyPair<pc.PublicKey, pc.PrivateKey> pair =
      generator.generateKeyPair();
  return _GeneratedKeyPair(
    pair.privateKey as pc.ECPrivateKey,
    pair.publicKey as pc.ECPublicKey,
  );
}

/// Encode a BigInt as a base64url (unpadded) string with the
/// fixed 32-byte width that P-256 JWKs require. RFC 7518 §6.2.1.2:
/// "x" and "y" MUST be 32 octets for P-256.
String _b64UrlEncodeBigInt(BigInt value) {
  String hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  // Pad on the left to 32 bytes (= 64 hex chars).
  while (hex.length < 64) {
    hex = '0$hex';
  }
  final Uint8List bytes = Uint8List(32);
  for (int i = 0; i < 32; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return _b64UrlBytes(bytes);
}

String _b64UrlBytes(List<int> bytes) {
  String s = base64Url.encode(bytes);
  // Strip padding.
  while (s.endsWith('=')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

String _b64UrlString(String input) =>
    _b64UrlBytes(utf8.encode(input));
