// `dart:io`-backed environment lookup. Selected by conditional import
// on non-web platforms (iOS / Android / macOS / Windows / Linux).
//
// Kept in a separate file so the validator's `audience.dart` stays
// importable on Flutter web (which has no `dart:io`).

import 'dart:io' show Platform;

/// Read a process-environment variable, returning `null` if not set.
String? environment(String name) => Platform.environment[name];
