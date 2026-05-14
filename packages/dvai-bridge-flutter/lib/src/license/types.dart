// Type surface for the DVAI-Bridge offline JWT license system.
//
// The whole license flow is deliberately small:
//   1. A signed JWT (produced server-side by your license generator) is
//      either dropped at a platform-default path, pointed at via the
//      `licenseKeyPath` config option, or pasted directly into the
//      `licenseToken` config option.
//   2. The SDK reads it, verifies the ECDSA P-256 signature against the
//      key registry in `public_keys.dart`, and checks four runtime
//      claims:
//      - signature must verify against a known kid
//      - `exp` must be in the future
//      - `aud` must include the current audience (bundle id / hostname)
//      - `platforms` must include `flutter`
//   3. The outcome is summarised in a [LicenseStatus] value that the
//      rest of the SDK can dispatch on (commercial/trial → premium
//      behaviour; everything else → free-tier behaviour with the
//      "Powered by DVAI Bridge" attribution badge).
//
// Nothing in this file makes network calls. The entire flow is offline.

import 'package:meta/meta.dart';

/// Platform identifiers the SDK recognises in license `platforms`
/// claims. The wire format matches the JS-side enum string values
/// exactly so the same JWT can activate multiple SDKs.
enum DvaiPlatform {
  /// Browser / JS host (the JS SDK).
  web('web'),

  /// Node.js (the JS SDK in a server-side context).
  node('node'),

  /// iOS-native SDK (`dvai-bridge-ios-*`).
  ios('ios'),

  /// Android-native SDK (`dvai-bridge-android-*`).
  android('android'),

  /// .NET / MAUI SDK (`dvai-bridge-dotnet`).
  dotnet('dotnet'),

  /// Flutter SDK (this package).
  flutter('flutter'),

  /// React-Native SDK.
  reactNative('react-native'),

  /// Capacitor SDK.
  capacitor('capacitor');

  const DvaiPlatform(this.wire);

  /// Wire-format identifier as it appears in the JWT `platforms` claim.
  final String wire;

  /// Decode a wire-format string into a [DvaiPlatform]. Returns null
  /// if the value isn't a recognised platform — the caller treats
  /// unknowns as a non-match.
  static DvaiPlatform? fromWire(String value) {
    for (final DvaiPlatform p in DvaiPlatform.values) {
      if (p.wire == value) return p;
    }
    return null;
  }
}

/// Decoded license-payload shape we issue. Extra claims are tolerated;
/// the validator only reads the ones below.
@immutable
class DvaiLicensePayload {
  /// Construct a payload. Used internally by the validator to surface
  /// the decoded claims; consumers rarely construct one by hand.
  const DvaiLicensePayload({
    required this.iss,
    required this.sub,
    required this.aud,
    required this.tier,
    required this.platforms,
    required this.licensee,
    required this.iat,
    required this.exp,
  });

  /// Standard JWT issuer claim. Must be `"DVAI-Bridge"`.
  final String iss;

  /// Standard subject — our internal license id. Surfaced in audit logs.
  final String sub;

  /// Audience binding — array of domains and/or bundle ids permitted to
  /// activate this license. Each entry is either an exact string match
  /// (e.g. `"com.acme.app"`) or a wildcard subdomain pattern
  /// (e.g. `"*.acme.com"` matches both `acme.com` and `app.acme.com`).
  final List<String> aud;

  /// Tier the license grants. Always `"commercial"` or `"trial"` —
  /// the validator never produces `free-*` here (those are computed).
  final String tier;

  /// Which DVAI-Bridge SDK platforms this license activates. The
  /// current runtime platform must appear here for the license to
  /// apply.
  final List<DvaiPlatform> platforms;

  /// Display name of the licensee, for audit logs + user-facing
  /// messaging.
  final String licensee;

  /// Standard JWT issued-at (seconds since Unix epoch).
  final int iat;

  /// Standard JWT expiry (seconds since Unix epoch).
  final int exp;
}

/// Result of license validation. Discriminated sealed-class union so
/// the consumer's decision tree is exhaustive (`Commercial` or `Trial`
/// → premium; everything else → free).
@immutable
sealed class LicenseStatus {
  /// Base constructor — subclass-only.
  const LicenseStatus();

  /// Stable string discriminator, mirroring the JS-side `kind`
  /// field on `LicenseStatus`. Lets host-app dashboards switch on
  /// the value without pattern-matching on the runtime type.
  String get kind;
}

/// Paid commercial license — the SDK runs without the "Powered by
/// DVAI Bridge" badge.
@immutable
class Commercial extends LicenseStatus {
  /// Construct a commercial-license status.
  const Commercial({
    required this.licensee,
    required this.expiresAt,
    required this.platform,
    required this.audienceMatched,
  });

  /// Display name of the licensee. Mirrors `licensee` from the JWT.
  final String licensee;

  /// Unix-seconds expiry from the JWT `exp` claim.
  final int expiresAt;

  /// Platform the validator detected at runtime (always
  /// [DvaiPlatform.flutter] on this SDK).
  final DvaiPlatform platform;

  /// Which `aud` entry from the JWT matched the runtime audience.
  /// Recorded for audit / logging.
  final String audienceMatched;

  @override
  String get kind => 'commercial';
}

/// Trial license — same behaviour as [Commercial], distinct only for
/// audit + dashboard surfacing.
@immutable
class Trial extends LicenseStatus {
  /// Construct a trial-license status.
  const Trial({
    required this.licensee,
    required this.expiresAt,
    required this.platform,
    required this.audienceMatched,
  });

  /// Display name of the licensee.
  final String licensee;

  /// Unix-seconds expiry from the JWT `exp` claim.
  final int expiresAt;

  /// Platform the validator detected at runtime.
  final DvaiPlatform platform;

  /// Which `aud` entry matched.
  final String audienceMatched;

  @override
  String get kind => 'trial';
}

/// Dev-mode bypass — the SDK proceeds without checking a license. The
/// [reason] is surfaced via host-app dashboards.
@immutable
class FreeDev extends LicenseStatus {
  /// Construct a dev-mode status with a human-readable reason.
  const FreeDev(this.reason);

  /// Why dev mode was detected (for logging / dashboard surfacing).
  final String reason;

  @override
  String get kind => 'free-dev';
}

/// Production deploy with no valid license. The `validate()` API
/// returns this; `validateAndAssert()` THROWS
/// [LicenseRequiredException] with a [FreeProd] status attached.
@immutable
class FreeProd extends LicenseStatus {
  /// Construct a free-prod status with the failure reason.
  const FreeProd(this.reason);

  /// Why a license could not be loaded or validated. Surfaced via the
  /// thrown [LicenseRequiredException] so the developer can debug.
  final String reason;

  @override
  String get kind => 'free-prod';
}

/// Had a valid license but `exp` is past. The `validate()` API
/// returns this; `validateAndAssert()` THROWS
/// [LicenseRequiredException] with a [FreeExpired] status attached.
@immutable
class FreeExpired extends LicenseStatus {
  /// Construct an expired-license status with the licensee + expiry.
  const FreeExpired({
    required this.licensee,
    required this.expiredAt,
  });

  /// Display name of the licensee whose license expired.
  final String licensee;

  /// Unix-seconds expiry from the JWT `exp` claim.
  final int expiredAt;

  @override
  String get kind => 'free-expired';
}

/// Returns true iff [status] represents a paid / unwatermarked tier.
bool isPaidTier(LicenseStatus status) {
  return status is Commercial || status is Trial;
}

/// Thrown by [LicenseValidator.validateAndAssert] when an SDK consumer
/// attempts to run the library in a production / release context
/// without a valid commercial or trial license.
///
/// The error message is intentionally verbose: it tells the developer
/// exactly which check failed (missing file, expired, audience
/// mismatch, etc.), how to resolve it, and where to put the license
/// file once they have one. This is the front line of the BSL 1.1
/// commercial enforcement story — surface it clearly enough that a
/// developer can unblock themselves without a support ticket.
///
/// The [status] field carries the underlying [LicenseStatus] so
/// programmatic callers can dispatch on `err.status` if they want to
/// handle "expired" differently from "missing".
class LicenseRequiredException implements Exception {
  /// Construct an exception from the failure status + the verbose
  /// developer-facing message.
  const LicenseRequiredException(this.message, this.status);

  /// Developer-facing message describing what failed + how to fix.
  final String message;

  /// Underlying validator status that triggered the throw.
  final LicenseStatus status;

  @override
  String toString() => 'LicenseRequiredException: $message';
}
