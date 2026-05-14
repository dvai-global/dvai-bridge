// Web-build stub for `discovery_io.dart`. Web has no `dart:io` and no
// filesystem access; every read returns null and the discovery layer
// falls through to the asset-bundle branch.

/// Stub for filesystem reads on web. Always returns null.
Future<String?> readFile(String path) async => null;

/// Stub for documents-directory reads on web. Always returns null.
Future<String?> readFromDocumentsDirectory(String filename) async => null;
