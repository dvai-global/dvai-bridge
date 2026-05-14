// License-file discovery for the Flutter SDK.
//
// The SDK reads the license JWT from (in priority order):
//
//   1. An explicit string literal passed as `token` — useful for CI /
//      serverless / contexts where reading a file isn't practical and
//      the operator wants to inject via env var instead.
//
//   2. A path passed as `path` — the developer points the SDK at a
//      file they've placed somewhere non-default.
//
//   3. The `DVAI_LICENSE_PATH` env var — same as (2) but driven by
//      process environment, helpful for desktop deployments.
//
//   4. The `DVAI_LICENSE_TOKEN` env var — inline-token alternative to
//      a file, helpful for CI.
//
//   5. The bundled asset `assets/dvai-license.jwt` (consumers must
//      declare it under `flutter.assets` in their `pubspec.yaml`).
//
//   6. The application's Documents directory
//      (`<documents>/dvai-license.jwt`) — dev-friendly happy path on
//      iOS / Android where the app has read access to its own sandbox.
//
// Returning `null` means "no license file found"; the validator
// treats that as the free-tier case (after dev-mode bypass).

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:meta/meta.dart';

// Conditional imports — `dart:io` and `path_provider` are not
// available on web. The stubs return null so the discovery layer
// silently skips those branches on web.
import 'audience_io_stub.dart' if (dart.library.io) 'audience_io.dart'
    as platform_io;
import 'discovery_io_stub.dart' if (dart.library.io) 'discovery_io.dart'
    as fs_io;

/// Default filename the SDK looks for. Chosen to be self-documenting
/// and to encourage commit-to-vcs (so the license travels with the
/// code, audited and reviewable by the team).
const String defaultLicenseFilename = 'dvai-license.jwt';

/// Default asset key the SDK loads via [rootBundle]. Mirrors the
/// JS-side `/dvai-license.jwt` convention while staying inside
/// Flutter's `assets/` convention.
const String defaultLicenseAssetKey = 'assets/$defaultLicenseFilename';

/// A discovered token + the source that produced it. The `source`
/// label is purely informational — surfaced in logs / dashboards so
/// the developer can tell which path won.
@immutable
class DiscoveredLicense {
  /// Construct a discovered-license record.
  const DiscoveredLicense({required this.token, required this.source});

  /// Raw JWT string (already trimmed of whitespace).
  final String token;

  /// Human-readable label for where the token came from
  /// (`"explicit-token"`, `"env:DVAI_LICENSE_PATH=..."`, etc.).
  final String source;
}

/// Discovery options accepted by [discoverLicenseToken]. Mirrors the
/// JS-side `LicenseDiscoveryOptions` shape — `token` is the inline
/// JWT, `path` is an explicit filesystem path.
@immutable
class LicenseDiscoveryOptions {
  /// Construct discovery options.
  const LicenseDiscoveryOptions({this.token, this.path});

  /// Pre-loaded JWT string. When set, skips all filesystem / asset
  /// lookups.
  final String? token;

  /// Explicit filesystem path to load from. Overrides auto-discovery.
  final String? path;
}

/// Best-effort load of a license JWT. Returns the raw token string on
/// success or null on miss. Errors during loading (file not found,
/// asset missing) collapse to null — the validator's responsibility
/// is to handle the no-license case gracefully, not the discovery
/// layer's.
Future<DiscoveredLicense?> discoverLicenseToken([
  LicenseDiscoveryOptions opts = const LicenseDiscoveryOptions(),
]) async {
  // 1. Explicit token wins.
  final String? inlineToken = opts.token;
  if (inlineToken != null && inlineToken.isNotEmpty) {
    return DiscoveredLicense(
      token: inlineToken.trim(),
      source: 'options.token',
    );
  }

  // 2. Explicit path (config option). An explicit path that doesn't
  //    load is a real miss, not a silent fallthrough — mirrors the
  //    JS-side semantics.
  final String? explicitPath = opts.path;
  if (explicitPath != null && explicitPath.isNotEmpty) {
    final String? loaded = await fs_io.readFile(explicitPath);
    if (loaded != null) {
      return DiscoveredLicense(token: loaded, source: explicitPath);
    }
    return null;
  }

  // 3. Env-var path (desktop / server only — env vars don't exist on
  //    iOS / Android / web, where the lookup returns null).
  final String? envPath = platform_io.environment('DVAI_LICENSE_PATH');
  if (envPath != null && envPath.isNotEmpty) {
    final String? loaded = await fs_io.readFile(envPath);
    if (loaded != null) {
      return DiscoveredLicense(
        token: loaded,
        source: 'env:DVAI_LICENSE_PATH=$envPath',
      );
    }
  }

  // 4. Env-var inline token (alternative to file for serverless / CI).
  final String? envToken = platform_io.environment('DVAI_LICENSE_TOKEN');
  if (envToken != null && envToken.isNotEmpty) {
    return DiscoveredLicense(
      token: envToken.trim(),
      source: 'env:DVAI_LICENSE_TOKEN',
    );
  }

  // 5. Bundled asset. Works on every Flutter platform including web.
  final String? asset = await _tryLoadAsset(defaultLicenseAssetKey);
  if (asset != null) {
    return DiscoveredLicense(token: asset, source: defaultLicenseAssetKey);
  }

  // 6. Documents directory (iOS / Android / desktop only — skipped on
  //    web where there's no filesystem).
  if (!kIsWeb) {
    final String? documents = await fs_io.readFromDocumentsDirectory(
      defaultLicenseFilename,
    );
    if (documents != null) {
      return DiscoveredLicense(
        token: documents,
        source: '<documents>/$defaultLicenseFilename',
      );
    }
  }

  return null;
}

Future<String?> _tryLoadAsset(String key) async {
  try {
    final String raw = await rootBundle.loadString(key);
    final String trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  } catch (_) {
    return null;
  }
}
