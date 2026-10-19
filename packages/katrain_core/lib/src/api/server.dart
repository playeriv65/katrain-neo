// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/api/server.py: the HTTP
// server in the app. Listens on 127.0.0.1 only and requires a per-run token.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../constants.dart';
import 'commands.dart';
import 'protocol.dart';

const maxBody = 16 * 1024 * 1024;

/// Turns off the API when set to 0.
const apiEnabledVariable = 'KATRAIN_NEO_API';

/// Overrides the configured port.
const apiPortVariable = 'KATRAIN_NEO_API_PORT';

/// JSON can't hold NaN or infinities; they go out as null.
Object? _jsonSafe(Object? v) {
  if (v is double && !v.isFinite) return null;
  if (v is Map) return {for (final e in v.entries) '${e.key}': _jsonSafe(e.value)};
  if (v is Iterable) return [for (final x in v) _jsonSafe(x)];
  return v;
}

class ApiServer {
  final CommandHandler handler;
  final String version;
  final void Function(String message, num level) log;
  final String token;
  final DateTime started = DateTime.now();
  final String? discoveryPath;
  late final HttpServer _http;

  ApiServer._(this.handler, this.version, this.log, this.token, this.discoveryPath);

  int get port => _http.port;

  /// Binds the first free port from [port] on and writes the discovery file.
  static Future<ApiServer> start(
    CommandHandler handler, {
    required String version,
    required void Function(String message, num level) log,
    int port = defaultApiPort,
    String? discoveryPath,
  }) async {
    final random = Random.secure();
    final token = base64Url.encode([for (var i = 0; i < 24; i++) random.nextInt(256)]).replaceAll('=', '');
    final server = ApiServer._(handler, version, log, token, discoveryPath);
    Object? lastError;
    for (var candidate = port; candidate < port + portSearchRange; candidate++) {
      try {
        server._http = await HttpServer.bind(InternetAddress.loopbackIPv4, candidate);
        lastError = null;
        break;
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) throw SocketException('no free port in $port-${port + portSearchRange - 1}: $lastError');
    server._http.listen(server._serve);
    writeDiscovery({
      'api_version': apiVersion,
      'katrain_version': version,
      'host': '127.0.0.1',
      'port': server.port,
      'token': token,
      'pid': pid,
      'started': server.started.millisecondsSinceEpoch / 1000, // seconds, like Python's time.time()
    }, discoveryPath);
    log('KaTrain Neo API listening on 127.0.0.1:${server.port}', outputInfo);
    return server;
  }

  Future<void> stop() async {
    removeDiscovery(pid, discoveryPath);
    await _http.close(force: true);
  }

  Map<String, Object?> health() => {
    'api_version': apiVersion,
    'katrain_version': version,
    'pid': pid,
    'uptime': (DateTime.now().difference(started).inMilliseconds / 100).round() / 10,
  };

  Future<Map<String, Object?>> execute(String command, ApiArgs args) async {
    try {
      return {'ok': true, 'result': await handler.dispatch(command, args)};
    } on ApiError catch (e) {
      return {'ok': false, 'error': e.toJson()};
    } on Object catch (e, st) {
      log('[api] command $command failed: $e\n$st', outputError);
      return {
        'ok': false,
        'error': {'code': 'internal_error', 'message': '${e.runtimeType}: $e'},
      };
    }
  }

  bool _authorized(HttpRequest request) {
    final given = utf8.encode(request.headers.value(tokenHeader) ?? '');
    final expected = utf8.encode(token);
    var diff = given.length ^ expected.length; // constant time, like hmac.compare_digest
    for (var i = 0; i < given.length && i < expected.length; i++) {
      diff |= given[i] ^ expected[i];
    }
    return diff == 0;
  }

  Future<void> _reply(HttpRequest request, int status, Map<String, Object?> payload) async {
    String body;
    try {
      body = jsonEncode(_jsonSafe(payload));
    } on Object catch (e) {
      status = 500;
      body = jsonEncode({
        'ok': false,
        'error': {'code': 'internal_error', 'message': 'could not encode the result: $e'},
      });
    }
    final bytes = utf8.encode(body);
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
      ..contentLength = bytes.length
      ..add(bytes);
    await request.response.close();
  }

  Future<void> _serve(HttpRequest request) async {
    log('[api] ${request.connectionInfo?.remoteAddress.address} ${request.method} ${request.uri.path}', outputDebug);
    final path = request.uri.path;
    Map<String, Object?> error(String code, String message) => {
      'ok': false,
      'error': {'code': code, 'message': message},
    };
    try {
      if (request.method == 'GET') {
        if (path != healthPath) return await _reply(request, 404, error('not_found', path));
        if (!_authorized(request)) return await _reply(request, 401, error('unauthorized', 'bad token'));
        return await _reply(request, 200, {'ok': true, 'result': health()});
      }
      if (request.method != 'POST' || path != commandPath) return await _reply(request, 404, error('not_found', path));
      if (!_authorized(request)) return await _reply(request, 401, error('unauthorized', 'bad token'));
      if (request.contentLength > maxBody) return await _reply(request, 400, error('bad_request', 'request too large'));
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
        if (bytes.length > maxBody) return await _reply(request, 400, error('bad_request', 'request too large'));
      }
      final Object? body;
      try {
        body = bytes.isEmpty ? <String, Object?>{} : jsonDecode(utf8.decode(bytes));
      } on FormatException catch (e) {
        return await _reply(request, 400, error('bad_request', e.message));
      }
      final command = body is Map ? body['command'] : null;
      final args = body is Map ? (body['args'] ?? <String, Object?>{}) : null;
      if (command is! String || args is! Map) {
        return await _reply(request, 400, error('bad_request', "expected {'command': str, 'args': object}"));
      }
      await _reply(request, 200, await execute(command, args.cast<String, dynamic>()));
    } on Object catch (e) {
      log('[api] request failed: $e', outputError);
    }
  }
}

/// Starts the API unless it is turned off (setting `api/enabled`, or KATRAIN_NEO_API=0). Never throws.
Future<ApiServer?> startApiServer(
  CommandHandler handler, {
  required Object? Function(String setting, [Object? defaultValue]) config,
  required String version,
  required void Function(String message, num level) log,
}) async {
  if (Platform.environment[apiEnabledVariable] == '0' || config('api/enabled', true) == false) return null;
  try {
    final port =
        int.tryParse(Platform.environment[apiPortVariable] ?? '') ?? (config('api/port', defaultApiPort) as int);
    return await ApiServer.start(handler, version: version, log: log, port: port);
  } on Object catch (e) {
    log('Failed to start KaTrain Neo API: $e', outputError);
    return null;
  }
}
