// Runtime audience + platform + dev-mode detection for the Flutter SDK.
//
// Native SDKs (iOS, Android, .NET, JS) re-implement the same semantics
// in their own languages — the platform identifier and the audience
// source differ, but the JWT format and the audience-matching rules
// (exact + `*.example.com` wildcard + `*` permissive) are identical
// across SDKs so a single `.jwt` license can authorise multiple
// platforms.
//
// For the Flutter SDK, "audience" means:
//   - the bundle id / application id reported by `package_info_plus`
//     (e.g. `com.acme.app` on Android, the bundle identifier on iOS,
//     the package name on Windows / Linux / macOS / web)
//
// "Dev mode" detection bypasses license enforcement entirely so
// developers don't need a license to run the SDK in `flutter run` or
// `flutter test`. Match the JS-side bypass list as closely as the
// Flutter runtime allows.

import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, kProfileMode, kReleaseMode;
import 'package:package_info_plus/package_info_plus.dart' show PackageInfo;

// Conditional import — `dart:io` doesn't exist on web. The stub
// (`audience_io_stub.dart`) supplies the same surface for web builds.
import 'audience_io_stub.dart' if (dart.library.io) 'audience_io.dart'
    as platform_io;

/// Result of [detectDevMode]. Mirrors the JS-side
/// `{ isDev: boolean; reason: string }` shape.
class DevModeDetection {
  /// Construct a detection result.
  const DevModeDetection({required this.isDev, required this.reason});

  /// Whether the SDK should bypass license enforcement.
  final bool isDev;

  /// Why the bypass was applied. Surfaced in [FreeDev.reason] for
  /// host-app dashboards.
  final String reason;
}

/// Detect the current SDK platform identifier. The Flutter SDK always
/// reports [DvaiPlatform.flutter] regardless of the underlying OS —
/// what matters is which SDK API is being called, not which native
/// runtime hosts the Dart VM. Mirrors the .NET SDK's flat-identifier
/// model.
String detectPlatform() => 'flutter';

/// Detect the current audience the license must bind. Returns `null`
/// when no determinable audience exists (e.g. running in a unit-test
/// host where `PackageInfo.fromPlatform()` isn't bound) — the
/// validator handles null by accepting only `"*"` aud entries.
///
/// On web, falls back to `Uri.base.host` when the package name isn't
/// useful (web builds typically report the manifest `name`, which is
/// less useful for license binding than the deploy hostname).
Future<String?> detectAudience() async {
  // Operator-supplied override wins on every platform. Mirrors the
  // JS-side `DVAI_AUDIENCE` env var.
  final String? envOverride = platform_io.environment('DVAI_AUDIENCE');
  if (envOverride != null && envOverride.isNotEmpty) {
    return envOverride;
  }

  if (kIsWeb) {
    // Web: the deploy hostname is the most useful binding. Falls
    // through to PackageInfo when running in a test where Uri.base
    // doesn't resolve to anything meaningful.
    final String webHost = Uri.base.host;
    if (webHost.isNotEmpty) return webHost;
  }

  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    final String pkg = info.packageName;
    if (pkg.isNotEmpty) return pkg;
  } catch (_) {
    // PackageInfo isn't bound in unit-test contexts unless the test
    // sets it up explicitly. Fall through to null so the validator's
    // `"*"` permissive-aud branch can still activate.
  }
  return null;
}

/// Detect whether the SDK is running in a developer environment where
/// license enforcement should be bypassed. The bypass list is
/// intentionally generous: blocking a developer mid-`flutter run`
/// with a license-not-found error would be hostile. The cost is that
/// a malicious actor pointing their build at debug mode could bypass
/// — but they could equally fork the SDK and remove the check, so the
/// dev-mode bypass adds no real attack surface.
DevModeDetection detectDevMode() {
  // 1. Explicit env-var overrides win.
  final String? forceProd = platform_io.environment('DVAI_FORCE_PROD');
  if (forceProd == '1' || forceProd == 'true') {
    return const DevModeDetection(isDev: false, reason: 'DVAI_FORCE_PROD set');
  }
  final String? forceDev = platform_io.environment('DVAI_FORCE_DEV');
  if (forceDev == '1' || forceDev == 'true') {
    return const DevModeDetection(isDev: true, reason: 'DVAI_FORCE_DEV set');
  }

  // 2. Flutter debug / profile builds are dev. Release is prod.
  //    kDebugMode and kProfileMode are compile-time constants — the
  //    tree-shaker prunes the corresponding branches in release builds.
  if (kDebugMode) {
    return const DevModeDetection(isDev: true, reason: 'kDebugMode');
  }
  if (kProfileMode) {
    return const DevModeDetection(isDev: true, reason: 'kProfileMode');
  }

  // 3. Web localhost / private-network heuristic. Matches the JS-side
  //    bypass so the same `flutter run -d chrome` session that bypasses
  //    on the JS validator also bypasses here.
  if (kIsWeb) {
    final String host = Uri.base.host;
    if (host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.endsWith('.local') ||
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        host.startsWith('172.')) {
      return DevModeDetection(
        isDev: true,
        reason: 'localhost-class hostname: $host',
      );
    }
  }

  // 4. Release build with no override → production.
  if (kReleaseMode) {
    return const DevModeDetection(
      isDev: false,
      reason: 'production-class environment (kReleaseMode)',
    );
  }
  // Defensive default — should be unreachable in practice since one of
  // kDebugMode / kProfileMode / kReleaseMode is always true.
  return const DevModeDetection(
    isDev: false,
    reason: 'production-class environment',
  );
}

/// Decide whether a license-payload `aud` entry matches the current
/// runtime audience. Supports exact match and `*.example.com` wildcard
/// matching for subdomain binding. Returns the matched `aud` pattern
/// on success so it can be recorded for audit, or null on miss.
///
/// Match rules (mirror the JS-side semantics exactly):
///   - `"foo"` matches `"foo"` exactly (case-insensitive)
///   - `"*.example.com"` matches `"example.com"` AND any
///     `"<sub>.example.com"`
///   - `"*"` matches any non-empty audience (intentionally permissive;
///     use for trial / site licenses that span all of a customer's
///     deployments)
///
/// Runtime audience of `null` matches `"*"` only — a host without a
/// determinable bundle id can activate "any-audience" licenses but not
/// audience-bound ones. This is the safe default; operators that want
/// stricter binding set DVAI_AUDIENCE explicitly.
String? matchAudience(String? runtimeAudience, List<String> audClaim) {
  if (runtimeAudience == null) {
    return audClaim.contains('*') ? '*' : null;
  }
  final String runtime = runtimeAudience.toLowerCase();
  for (final String pattern in audClaim) {
    final String p = pattern.toLowerCase();
    if (p == '*') return pattern; // permissive wildcard
    if (p == runtime) return pattern; // exact match
    if (p.startsWith('*.')) {
      final String suffix = p.substring(2);
      if (runtime == suffix || runtime.endsWith('.$suffix')) {
        return pattern;
      }
    }
  }
  return null;
}
