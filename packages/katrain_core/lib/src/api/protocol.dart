// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/api/protocol.py:
// constants and the error type shared by the API server and the CLI client.

import 'dart:convert';
import 'dart:io';

import '../config/katrain_base.dart' show neoDataFolder;
import '../engine/io/local_katago.dart' show expandUser;

const apiVersion = 1;
const defaultApiPort = 8765;
const portSearchRange = 10;
const commandPath = '/v1/command';
const healthPath = '/v1/health';
const tokenHeader = 'X-KaTrain-Token';

/// Where a running KaTrain Neo says how to reach its API.
String get discoveryFile => '${expandUser(neoDataFolder)}${Platform.pathSeparator}api.json';

/// An error reported back to the client as `{"ok": false, "error": {...}}`.
class ApiError implements Exception {
  final String code;
  final String message;
  final Map<String, Object?> details;
  ApiError(this.code, this.message, [this.details = const {}]);

  Map<String, Object?> toJson() => {'code': code, 'message': message, ...details};

  @override
  String toString() => '$code: $message';
}

/// The connection info written by a running app, or null.
Map<String, dynamic>? readDiscovery([String? path]) {
  try {
    return jsonDecode(File(path ?? discoveryFile).readAsStringSync()) as Map<String, dynamic>;
  } on Object {
    return null;
  }
}

void writeDiscovery(Map<String, Object?> info, [String? path]) {
  final file = File(path ?? discoveryFile);
  file.parent.createSync(recursive: true);
  final tmp = File('${file.path}.tmp');
  tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(info));
  tmp.renameSync(file.path);
}

/// Removes the discovery file, but only if it still belongs to process [pid].
void removeDiscovery(int pid, [String? path]) {
  final info = readDiscovery(path);
  if (info != null && info['pid'] == pid) {
    try {
      File(path ?? discoveryFile).deleteSync();
    } on FileSystemException {
      // already gone
    }
  }
}
