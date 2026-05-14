// DVAI-Bridge license validator — offline JWT verification (Flutter SDK).
//
// The Flutter port of the canonical JS/TS implementation in
// `packages/dvai-bridge-core/src/license`. The semantics — JWT format,
// claim shape, audience matching, platform binding, throw-on-prod
// policy — are byte-for-byte identical: a single `.jwt` license signed
// by the operator's license-generator service activates Flutter, iOS,
// Android, .NET, and JS SDKs from the same file.
//
// Cryptography is delegated to `dart_jsonwebtoken` (which delegates in
// turn to `pointycastle`). The validator refuses any algorithm other
// than `ES256` so the classic JWT algorithm-confusion vulnerability
// can't be exploited via crafted `alg: none` / `alg: HS256` tokens.
//
// Network calls: zero. The whole flow is offline by design — there's
// no "phone home" step, no license server polling, no DRM beacon. The
// private-key holder is the only party that can mint tokens, and any
// deployment that has a valid file activates without contacting us.

import 'dart:async';
import 'dart:convert' show jsonDecode, utf8, base64Url;

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart'
    show
        ECPublicKey,
        JWT,
        JWTExpiredException,
        JWTInvalidException,
        JWTKey,
        JWTParseException;

import 'audience.dart';
import 'discovery.dart';
import 'public_keys.dart';
import 'types.dart';

/// Options accepted by [LicenseValidator]. Mirrors the JS-side
/// `LicenseValidatorOptions` interface — extends the discovery
/// options with key-registry overrides used by tests.
class LicenseValidatorOptions {
  /// Construct validator options.
  const LicenseValidatorOptions({
    this.token,
    this.path,
    this.publicKeys,
    this.allowPlaceholderKey = false,
    this.devModeOverride,
    this.audienceOverride,
  });

  /// Inline JWT to validate. Skips all filesystem / asset lookups.
  /// Mirrors `StartOptions.licenseToken`.
  final String? token;

  /// Explicit path to load the JWT from. Mirrors
  /// `StartOptions.licenseKeyPath`.
  final String? path;

  /// Override the public-key registry. Defaults to the top-level
  /// `publicKeys` constant in `public_keys.dart`. Tests inject their
  /// own keypair via this option so they can sign + verify against a
  /// deterministic key without polluting the production registry.
  final Map<String, DvaiPublicKey>? publicKeys;

  /// If true, accept tokens signed under [placeholderKid]. Off by
  /// default — a real production build must replace the placeholder
  /// with a generated key. Tests set this to true.
  final bool allowPlaceholderKey;

  /// Test-only — override the auto-detected dev-mode signal. The JS
  /// SDK manipulates `process.env.DVAI_FORCE_PROD` in tests to flip
  /// between dev/prod modes; Dart cannot mutate `Platform.environment`
  /// at runtime, so the validator accepts an explicit override here.
  /// Production code leaves this null and uses the [detectDevMode]
  /// auto-detection (debug build / env vars / web localhost).
  final DevModeDetection? devModeOverride;

  /// Test-only — override the auto-detected runtime audience. The
  /// auto-detector reads from `package_info_plus` (which requires a
  /// bound `WidgetsFlutterBinding`) and `Uri.base.host`; tests
  /// inject a synthetic value here so they can exercise the
  /// audience-binding paths without standing up a fake platform
  /// channel. Pass `''` (empty string) to force null-audience
  /// behaviour. Production code leaves this null.
  final String? audienceOverride;
}

/// Validate a DVAI-Bridge license once at SDK startup. The returned
/// [LicenseStatus] is the discriminated value the rest of the SDK
/// dispatches on. [validate] never throws on validation failure — it
/// returns a [FreeProd] / [FreeExpired] status. [validateAndAssert]
/// throws [LicenseRequiredException] for those statuses and is the
/// BSL 1.1 enforcement point the public [DVAIBridge.start] uses.
class LicenseValidator {
  /// Construct a validator with the given options.
  LicenseValidator([LicenseValidatorOptions? opts])
      : _opts = opts ?? const LicenseValidatorOptions();

  final LicenseValidatorOptions _opts;

  /// Validate WITHOUT throwing. Returns a [LicenseStatus] describing
  /// what the validator determined; never throws on missing / invalid
  /// / expired licenses. Useful for host-app dashboards that want to
  /// display the licensee / expiry / fallback reason without halting
  /// SDK startup, and for tests.
  ///
  /// The SDK's [DVAIBridge.start] calls [validateAndAssert] instead —
  /// that throws [LicenseRequiredException] for `free-prod` /
  /// `free-expired`, which is how the BSL 1.1
  /// commercial-only-in-production policy is actually enforced at
  /// runtime.
  ///
  /// Idempotent; safe to call multiple times.
  Future<LicenseStatus> validate() async {
    // 1. Dev-mode bypass — license required only in production. Tests
    //    pass an explicit override since Dart can't mutate
    //    Platform.environment at runtime.
    final DevModeDetection dev = _opts.devModeOverride ?? detectDevMode();
    if (dev.isDev) {
      return FreeDev(dev.reason);
    }

    // 2. Discover the token. Returns null when no license source is
    //    configured AND auto-discovery fails — fall through to
    //    free-prod so the SDK still works for community / hobbyist
    //    users when `validate()` is called directly. The enforcement
    //    throw lives in `validateAndAssert()`.
    final DiscoveredLicense? discovered = await discoverLicenseToken(
      LicenseDiscoveryOptions(token: _opts.token, path: _opts.path),
    );
    if (discovered == null) {
      return const FreeProd(
        'no license token found; checked options.token, options.path, '
        'DVAI_LICENSE_PATH env, DVAI_LICENSE_TOKEN env, '
        'assets/dvai-license.jwt bundled asset, and '
        '<documents>/dvai-license.jwt',
      );
    }

    // 3. Verify signature + claims with dart_jsonwebtoken.
    final String runtimePlatform = detectPlatform();
    final String? runtimeAudience;
    final String? overrideAud = _opts.audienceOverride;
    if (overrideAud != null) {
      // An empty-string override means "force null-audience behaviour"
      // so tests can exercise the `aud: ["*"]`-only branch.
      runtimeAudience = overrideAud.isEmpty ? null : overrideAud;
    } else {
      runtimeAudience = await detectAudience();
    }
    return _verifyToken(discovered.token, runtimePlatform, runtimeAudience);
  }

  /// Strict validation entry point used by the SDK at startup.
  /// Returns [LicenseStatus] on success ([Commercial], [Trial],
  /// [FreeDev]) and THROWS [LicenseRequiredException] on [FreeProd] /
  /// [FreeExpired].
  ///
  /// This is the BSL 1.1 enforcement point: in production / release
  /// builds (any non-dev-mode environment), the SDK refuses to operate
  /// without a valid commercial or trial license. Developers running
  /// in debug / profile builds or with `DVAI_FORCE_DEV=1` are
  /// unaffected — those return a [FreeDev] status and the SDK proceeds
  /// normally.
  ///
  /// Use [validate] instead when you want to inspect the status
  /// without halting startup (host-app dashboards, test fixtures).
  Future<LicenseStatus> validateAndAssert() async {
    final LicenseStatus status = await validate();
    if (status is FreeProd || status is FreeExpired) {
      throw LicenseRequiredException(
        _buildRequiredErrorMessage(status),
        status,
      );
    }
    return status;
  }

  LicenseStatus _verifyToken(
    String token,
    String runtimePlatform,
    String? runtimeAudience,
  ) {
    final Map<String, DvaiPublicKey> registry =
        _opts.publicKeys ?? publicKeys;

    // Read the kid + alg out of the JWT header manually so we can
    // pick the right public key BEFORE handing the token to
    // dart_jsonwebtoken. Bypassing alg auto-selection gives us a
    // strong defence against the algorithm-confusion class of
    // vulnerabilities — any non-ES256 token is rejected before any
    // crypto runs.
    final List<String> parts = token.split('.');
    if (parts.length != 3 || parts[0].isEmpty) {
      return const FreeProd(
        'license token is not a well-formed JWT (need 3 segments)',
      );
    }

    final Map<String, dynamic> header;
    try {
      header = _decodeJsonSegment(parts[0]);
    } catch (err) {
      return FreeProd(
        'license token header is not parseable JSON: ${_asMessage(err)}',
      );
    }

    final dynamic alg = header['alg'];
    if (alg != 'ES256') {
      // Refuse `alg: none` and any non-ES256 algorithm. Critical
      // defense against the classic JWT algorithm-confusion
      // vulnerability.
      return FreeProd(
        'license token uses unsupported alg "${alg ?? '(missing)'}", '
        'expected ES256',
      );
    }

    final dynamic kid = header['kid'];
    if (kid is! String || kid.isEmpty) {
      return const FreeProd(
        'license token header missing kid; cannot select verification key',
      );
    }

    final DvaiPublicKey? publicKey = registry[kid];
    if (publicKey == null) {
      return FreeProd(
        'license token kid "$kid" is not in the SDK\'s public-key '
        'registry; either the key was rotated and you\'re on an old '
        'SDK, or the token was signed with a key we don\'t recognise',
      );
    }

    if (kid == placeholderKid && !_opts.allowPlaceholderKey) {
      return const FreeProd(
        'license token signed with the placeholder key '
        '(kid "$placeholderKid"); replace the placeholder in '
        'public_keys.dart with a real key generated via '
        'scripts/license/generate-keypair.mjs before issuing real '
        'licenses',
      );
    }

    // Convert our JWK shape into a dart_jsonwebtoken ECPublicKey.
    final JWTKey verificationKey;
    try {
      verificationKey = JWTKey.fromJWK(publicKey.toJwk());
      if (verificationKey is! ECPublicKey) {
        // The registry should only ever contain EC keys, but be
        // defensive against future shape changes.
        return const FreeProd(
          'license token verification key is not an EC public key',
        );
      }
    } catch (err) {
      return FreeProd(
        'license token verification key could not be parsed: '
        '${_asMessage(err)}',
      );
    }

    final JWT verified;
    try {
      verified = JWT.verify(
        token,
        verificationKey,
        issuer: 'DVAI-Bridge',
        // Audience and expiry are checked manually below so we can
        // surface specific failure reasons rather than generic
        // dart_jsonwebtoken error codes.
        checkExpiresIn: true,
      );
    } on JWTExpiredException {
      // Expired but otherwise valid — decode the payload so we can
      // surface the licensee/expiry for the developer's renewal flow.
      final Map<String, dynamic>? payload = _safeDecodePayload(parts[1]);
      final int exp = payload != null && payload['exp'] is num
          ? (payload['exp'] as num).toInt()
          : 0;
      final String licensee =
          payload != null && payload['licensee'] is String
              ? payload['licensee'] as String
              : '(unknown)';
      return FreeExpired(licensee: licensee, expiredAt: exp);
    } on JWTInvalidException catch (err) {
      // dart_jsonwebtoken folds signature failures and claim-mismatch
      // failures into JWTInvalidException with descriptive messages.
      // Distinguish by message content so the developer's console
      // warning is actionable.
      final String msg = err.message;
      if (msg.contains('invalid signature')) {
        return FreeProd(
          'license token signature did not verify against kid "$kid"; '
          'the token may have been tampered with or was signed by a '
          'different key',
        );
      }
      if (msg.contains('invalid issuer')) {
        return const FreeProd(
          'license token issuer is not "DVAI-Bridge"',
        );
      }
      return FreeProd('license token verification failed: $msg');
    } on JWTParseException catch (err) {
      return FreeProd(
        'license token parse failed: ${err.message}',
      );
    } catch (err) {
      return FreeProd(
        'license token verification failed: ${_asMessage(err)}',
      );
    }

    // Coerce + validate the payload shape ourselves (dart_jsonwebtoken
    // only checks the standard claims). Each branch below provides a
    // specific free-prod reason so the developer can fix exactly
    // what's wrong.
    final dynamic payload = verified.payload;
    final Map<String, dynamic>? payloadMap = _coercePayloadMap(payload);
    if (payloadMap == null) {
      return const FreeProd(
        'license token payload is not a JSON object',
      );
    }
    final DvaiLicensePayload? parsed = _parseLicensePayload(payloadMap);
    if (parsed == null) {
      return const FreeProd(
        'license token payload missing required DVAI fields '
        '(tier/platforms/aud/licensee)',
      );
    }

    if (!parsed.platforms.any((DvaiPlatform p) => p.wire == runtimePlatform)) {
      final String covered =
          parsed.platforms.map((DvaiPlatform p) => p.wire).join(', ');
      return FreeProd(
        'license token does not authorise platform "$runtimePlatform"; '
        'the token covers [$covered]',
      );
    }

    final String? matched = matchAudience(runtimeAudience, parsed.aud);
    if (matched == null) {
      final String entries = parsed.aud.join(', ');
      final String audSummary = runtimeAudience ?? '(none)';
      final String hint = runtimeAudience == null
          ? ' — set DVAI_AUDIENCE in your environment, or use a "*" '
              'aud entry for any-audience licenses'
          : '';
      return FreeProd(
        'license token\'s audience entries [$entries] do not match the '
        'current runtime audience "$audSummary"$hint',
      );
    }

    final DvaiPlatform resolvedPlatform =
        DvaiPlatform.fromWire(runtimePlatform) ?? DvaiPlatform.flutter;
    if (parsed.tier == 'trial') {
      return Trial(
        licensee: parsed.licensee,
        expiresAt: parsed.exp,
        platform: resolvedPlatform,
        audienceMatched: matched,
      );
    }
    return Commercial(
      licensee: parsed.licensee,
      expiresAt: parsed.exp,
      platform: resolvedPlatform,
      audienceMatched: matched,
    );
  }
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

Map<String, dynamic>? _coercePayloadMap(dynamic payload) {
  if (payload is Map<String, dynamic>) return payload;
  if (payload is Map) {
    // dart_jsonwebtoken returns Map<dynamic, dynamic> for the decoded
    // payload — coerce to Map<String, dynamic> for our typed parser.
    final Map<String, dynamic> coerced = <String, dynamic>{};
    for (final MapEntry<dynamic, dynamic> entry in payload.entries) {
      if (entry.key is! String) return null;
      coerced[entry.key as String] = entry.value;
    }
    return coerced;
  }
  return null;
}

Map<String, dynamic> _decodeJsonSegment(String segment) {
  final String padded = _padBase64Url(segment);
  final List<int> bytes = base64Url.decode(padded);
  final dynamic decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('segment is not a JSON object');
  }
  return decoded;
}

Map<String, dynamic>? _safeDecodePayload(String segment) {
  try {
    return _decodeJsonSegment(segment);
  } catch (_) {
    return null;
  }
}

String _padBase64Url(String s) {
  final int rem = s.length % 4;
  if (rem == 0) return s;
  return s + ('=' * (4 - rem));
}

String _asMessage(Object err) {
  if (err is Exception) {
    final String s = err.toString();
    return s;
  }
  return err.toString();
}

DvaiLicensePayload? _parseLicensePayload(Map<String, dynamic> p) {
  final dynamic iss = p['iss'];
  final dynamic sub = p['sub'];
  final dynamic aud = p['aud'];
  final dynamic tier = p['tier'];
  final dynamic platforms = p['platforms'];
  final dynamic licensee = p['licensee'];
  final dynamic iat = p['iat'];
  final dynamic exp = p['exp'];

  if (iss is! String || sub is! String) return null;
  // `aud` is either a single string ("foo") or a JSON array of strings
  // (["foo", "bar"]) — RFC 7519 §4.1.3 allows both forms, and
  // dart_jsonwebtoken auto-collapses single-element audiences to the
  // string form on the wire.
  final List<String> audList = <String>[];
  if (aud is String) {
    audList.add(aud);
  } else if (aud is List) {
    for (final dynamic a in aud) {
      if (a is! String) return null;
      audList.add(a);
    }
  } else {
    return null;
  }
  if (tier is! String || (tier != 'commercial' && tier != 'trial')) {
    return null;
  }
  if (platforms is! List) return null;
  final List<DvaiPlatform> platformsParsed = <DvaiPlatform>[];
  for (final dynamic plat in platforms) {
    if (plat is! String) return null;
    final DvaiPlatform? known = DvaiPlatform.fromWire(plat);
    // Unknown platforms are tolerated in the JWT (other SDK versions
    // may add new ones); skip them in the parsed list so the
    // platform-binding check below sees only platforms the current
    // SDK actually recognises.
    if (known != null) platformsParsed.add(known);
  }
  if (licensee is! String) return null;
  if (iat is! num || exp is! num) return null;

  return DvaiLicensePayload(
    iss: iss,
    sub: sub,
    aud: audList,
    tier: tier,
    platforms: platformsParsed,
    licensee: licensee,
    iat: iat.toInt(),
    exp: exp.toInt(),
  );
}

/// Build the developer-facing error message for
/// [LicenseRequiredException]. Intentionally verbose: it tells the
/// developer exactly what failed, how to resolve it, where to put the
/// license file, and how to bypass for local development. This
/// message will be printed to a terminal / a logcat / a crash log
/// somewhere — make it readable in all three contexts.
String _buildRequiredErrorMessage(LicenseStatus status) {
  const String header =
      '\nDVAI-Bridge Commercial License Required\n'
      '=======================================\n';

  final String reason;
  if (status is FreeExpired) {
    final DateTime expiredAt =
        DateTime.fromMillisecondsSinceEpoch(status.expiredAt * 1000, isUtc: true);
    reason =
        'License for "${status.licensee}" expired at '
        '${expiredAt.toIso8601String()}.';
  } else if (status is FreeProd) {
    reason = status.reason;
  } else {
    reason = '(unknown status)';
  }

  const String remediation =
      '\nThis SDK is licensed under BSL 1.1 and requires a valid '
      'commercial\nor trial license to run in production / release builds.\n'
      '\n'
      'To resolve:\n'
      '  1. Obtain a license at https://deepvoiceai.com/dvai-bridge/license\n'
      '  2. Place the file at one of these locations (any will work):\n'
      '       - assets/dvai-license.jwt  (bundled Flutter asset)\n'
      '       - <application-documents-dir>/dvai-license.jwt\n'
      '       - the path you pass as StartOptions.licenseKeyPath\n'
      '       - the path in \$DVAI_LICENSE_PATH (desktop / server)\n'
      '       - inline JWT in StartOptions.licenseToken or '
      '\$DVAI_LICENSE_TOKEN\n'
      '  3. Re-run.\n'
      '\n'
      'Developing locally? The SDK auto-detects dev mode in:\n'
      '  - debug builds (kDebugMode == true — `flutter run`)\n'
      '  - profile builds (kProfileMode == true)\n'
      '  - DVAI_FORCE_DEV=1 environment variable (explicit override)\n'
      '  - web localhost / 127.0.0.1 / *.local hostnames\n'
      'Any of these silences this error and lets the SDK run without a '
      'license.\n';

  return '$header\n$reason\n$remediation';
}
