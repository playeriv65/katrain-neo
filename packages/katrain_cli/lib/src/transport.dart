// The HTTP transport to a running KaTrain Neo: finds its port and token in the discovery file, posts commands to
// /v1/command, checks /v1/health, and turns connection failures into NotRunning.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// katrain_core has no public library for the protocol alone; package:katrain_core/api.dart pulls in the server.
import 'package:katrain_core/api.dart';

/// The app is not running or not reachable (exit code 3).
class NotRunning implements Exception {
  final String message;
  NotRunning(this.message);

  @override
  String toString() => message;
}

/// A response envelope: `{"ok": true, "result": ...}` or `{"ok": false, "error": {"code", "message", ...}}`.
typedef Envelope = Map<String, dynamic>;

/// Seconds the app may search by default before answering a command that waits for the engine.
const analysisTimeout = 300;

/// One API call: the command, its arguments (null values are dropped when sending) and, for commands that wait
/// for the engine, the seconds the server may take (the client then waits 30 s longer).
class ApiCall {
  final String command;
  final Map<String, Object?> args;
  final int? timeout;
  const ApiCall(this.command, this.args, [this.timeout]);

  @override
  String toString() => 'ApiCall($command, $args, $timeout)';
}

/// Talks to a running KaTrain Neo over its local HTTP API.
class ApiClient {
  /// Reads the discovery file (`~/.katrain-neo/api.json`); replaceable for tests.
  final Map<String, dynamic>? Function() discovery;

  ApiClient({Map<String, dynamic>? Function()? discovery}) : discovery = discovery ?? (() => readDiscovery());

  (Uri, String) _connection(int? port) {
    final info = discovery();
    if (info == null) {
      throw NotRunning('KaTrain Neo is not running (no ~/.katrain-neo/api.json). Start it with: katrain-neo gui');
    }
    final p = port == null || port == 0 ? info['port'] : port;
    return (Uri.parse('http://127.0.0.1:$p'), '${info['token'] ?? ''}');
  }

  Future<Envelope> _request(String path, {Object? payload, int? port, int timeout = 60}) async {
    final (base, token) = _connection(port);
    // never route localhost via a proxy
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = Duration(seconds: timeout);
    try {
      return await _send(client, base.resolve(path), token, payload).timeout(Duration(seconds: timeout));
    } on TimeoutException {
      return _error('client_timeout', 'no answer within ${timeout}s');
    } on SocketException catch (e) {
      final reason = e.osError?.message.trim() ?? e.message;
      throw NotRunning('KaTrain Neo is not reachable ($reason). Start it with: katrain-neo gui');
    } on HttpException catch (e) {
      throw NotRunning('KaTrain Neo is not reachable (${e.message}). Start it with: katrain-neo gui');
    } finally {
      client.close(force: true);
    }
  }

  Future<Envelope> _send(HttpClient client, Uri uri, String token, Object? payload) async {
    final request = payload == null ? await client.getUrl(uri) : await client.postUrl(uri);
    request.headers.set(tokenHeader, token);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (payload != null) {
      final body = utf8.encode(jsonEncode(payload));
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      if (response.statusCode >= 400) {
        return _error('http_${response.statusCode}', 'HTTP Error ${response.statusCode}: ${response.reasonPhrase}');
      }
      return _error('bad_response', 'the API answered with invalid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      return _error('bad_response', 'the API answered with JSON that is not an object');
    }
    return decoded;
  }

  static Envelope _error(String code, String message) => {
    'ok': false,
    'error': {'code': code, 'message': message},
  };

  /// Executes one API command; returns the response envelope `{"ok": ..., "result"|"error": ...}`.
  Future<Envelope> call(String command, [Map<String, Object?>? args, int? port, int timeout = 60]) {
    final sent = {
      for (final e in (args ?? const {}).entries)
        if (e.value != null) e.key: e.value,
    };
    return _request(commandPath, payload: {'command': command, 'args': sent}, port: port, timeout: timeout);
  }

  Future<Envelope> health({int? port, int timeout = 3}) => _request(healthPath, port: port, timeout: timeout);
}
