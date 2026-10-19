// What a `katrain-neo` run needs from the outside world (output streams, the API client, standard input, the app
// launcher), the exit codes, and how responses are printed.

import 'dart:convert';
import 'dart:io';

import 'launch.dart';
import 'transport.dart';

const exitOk = 0, exitApiError = 1, exitUsage = 2, exitNotRunning = 3;

/// Seconds `gui` waits for the API of a started app.
const launchTimeout = 90;

/// Starts the app; see [launchGui].
typedef Launcher = Future<Envelope> Function({String? config, String? sgf, bool wait, int timeout});

/// What the CLI needs from the outside world; replaceable for tests.
class CliEnvironment {
  final StringSink out;
  final StringSink err;
  final ApiClient client;
  final String Function() readStdin;

  /// Makes a path absolute before it is sent to the app (which may run in another folder).
  final String Function(String) absolute;
  final Launcher? _launch;

  CliEnvironment({
    required this.out,
    required this.err,
    ApiClient? client,
    String Function()? readStdin,
    this.absolute = absolutePath,
    this._launch,
  }) : client = client ?? ApiClient(),
       readStdin = readStdin ?? readAllStdin;

  /// Starts the app ([launchGui] with the real executable unless a launcher was given).
  Future<Envelope> launch({String? config, String? sgf, bool wait = true, int timeout = launchTimeout}) =>
      _launch?.call(config: config, sgf: sgf, wait: wait, timeout: timeout) ??
      launchGui(client, config: config, sgf: sgf, wait: wait, timeout: timeout);

  /// Prints [response]: the result on success (exit 0), the error envelope otherwise (exit 1). With [textKey], a
  /// result that has this key prints only its value (`--ascii`).
  int report(Envelope response, {bool compact = false, String? textKey}) {
    if (response['ok'] != true) {
      out.writeln(formatJson({'ok': false, 'error': response['error']}, compact: compact));
      return exitApiError;
    }
    final result = response['result'];
    if (textKey != null && result is Map && result.containsKey(textKey)) {
      final text = result[textKey];
      out.writeln(text is String ? text : formatJson(text, compact: compact));
    } else {
      out.writeln(formatJson(result, compact: compact));
    }
    return exitOk;
  }
}

/// JSON indented by two spaces, or on one line with [compact]; non-ASCII text is kept as it is.
String formatJson(Object? obj, {bool compact = false}) =>
    compact ? jsonEncode(obj) : const JsonEncoder.withIndent('  ').convert(obj);

/// Standard input as text: UTF-8, else the system encoding.
String readAllStdin() {
  final bytes = <int>[];
  for (var b = stdin.readByteSync(); b >= 0; b = stdin.readByteSync()) {
    bytes.add(b);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return systemEncoding.decode(bytes);
  }
}
