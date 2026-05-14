// `dart:io` + `path_provider`-backed filesystem reads for the
// discovery layer. Selected by conditional import on non-web platforms.

import 'dart:async';
import 'dart:io' show File;

import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;

/// Read a UTF-8 text file from [path]. Returns null on any failure
/// (missing file, permission denied, decode error, etc.) — discovery
/// is best-effort.
Future<String?> readFile(String path) async {
  try {
    final File f = File(path);
    if (!await f.exists()) return null;
    final String raw = await f.readAsString();
    final String trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  } catch (_) {
    return null;
  }
}

/// Read `<application-documents-dir>/[filename]`. Returns null on any
/// failure (path_provider unbound, file missing, etc.).
Future<String?> readFromDocumentsDirectory(String filename) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    return await readFile('${dir.path}/$filename');
  } catch (_) {
    return null;
  }
}
