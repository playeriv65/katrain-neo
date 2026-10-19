// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/remote_engine.py: KataGo's analysis
// protocol over a WebSocket, with reconnects that resume outstanding queries.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../constants.dart';
import '../../i18n/i18n.dart';
import '../../utils/py_str_format.dart';
import '../katago_engine.dart';

/// Opens a WebSocket; a parameter so tests can provide their own.
typedef WebSocketConnector = Future<WebSocket> Function(String url);

class RemoteKataGo implements EngineConnection {
  static const readTimeout = Duration(seconds: 120);

  /// Reconnect before showing the recovery popup.
  static const reconnectAttempts = 6;
  static const reconnectBackoffSeconds = 1.0;
  static const reconnectMaxBackoffSeconds = 10.0;

  final KataGoEngine engine;
  final WebSocketConnector connector;
  late final String remoteUrl;
  WebSocket? _ws;
  StreamSubscription? _subscription;
  bool _closing = false;
  bool _reportedDead = false;
  bool _reconnecting = false;
  int _connId = 0;

  /// Waits between reconnect attempts; replaced in tests.
  Future<void> Function(Duration) sleep = Future<void>.delayed;

  RemoteKataGo(this.engine, {WebSocketConnector? connector})
    : connector = connector ?? ((url) => WebSocket.connect(url).timeout(readTimeout));

  /// Validates the URL and connects. False when there is no usable connection (the error is reported).
  Future<bool> start() async {
    remoteUrl = ((engine.config['remote_url'] as String?) ?? '').trim();
    if (remoteUrl.isEmpty) {
      engine.onError(i18n.tr('Remote KataGo URL is empty'), 'REMOTE-URL-MISSING', allowPopup: false);
      _reportedDead = true;
      return false;
    }
    if (!remoteUrl.startsWith('ws://') && !remoteUrl.startsWith('wss://')) {
      engine.onError(
        i18n.tr('Remote KataGo URL must start with ws:// or wss://'),
        'REMOTE-URL-INVALID',
        allowPopup: false,
      );
      _reportedDead = true;
      return false;
    }
    _closing = false;
    _reportedDead = false;
    _reconnecting = false;
    engine.host.log('Connecting to remote KataGo at $remoteUrl', outputDebug);
    try {
      _attach(await connector(remoteUrl));
    } on Object catch (e) {
      engine.onError(
        pyFormat(i18n.tr('Connecting to remote KataGo failed'), {'url': remoteUrl, 'error': e}),
        'REMOTE-CONNECT',
      );
      _ws = null;
      return false;
    }
    return true;
  }

  void _attach(WebSocket ws) {
    _connId += 1;
    final connId = _connId;
    _ws = ws;
    engine.connection = this;
    _subscription = ws.listen(
      (frame) {
        if (connId != _connId || _closing) return;
        final raw = frame is String ? frame : utf8.decode(frame as List<int>, allowMalformed: true);
        // a frame may contain several newline-delimited responses
        for (final line in const LineSplitter().convert(raw)) {
          if (line.trim().isNotEmpty) engine.handleRemoteLine(line.trim());
        }
      },
      onError: (Object e) {
        if (!_closing) _handleDisconnect('$e', connId);
      },
      onDone: () {
        if (_closing) return;
        final reason = (ws.closeReason ?? '').trim();
        _handleDisconnect(reason.isEmpty ? 'closed by remote' : reason, connId);
      },
      cancelOnError: true,
    );
  }

  @override
  bool get alive {
    // a missing socket is expected while reconnecting
    if (_reconnecting && !_closing) return true;
    return _ws != null && !_closing;
  }

  /// KaTrain's `check_alive(exception_if_dead=True)`.
  bool checkAlive({String osError = '', bool maybeOpenRecovery = false}) {
    final ok = alive;
    if (!ok) _reportDead(osError, allowPopup: maybeOpenRecovery);
    return ok;
  }

  @override
  void send(String line) {
    final ws = _ws;
    if (ws == null) return; // reconnecting: the query is resent once connected
    try {
      ws.add(line);
    } on Object catch (e) {
      engine.host.log('Unexpected exception sending to remote KataGo: $e', outputError);
      _handleDisconnect('$e', _connId);
    }
  }

  void _handleDisconnect(String osError, int connId) {
    if (_closing || _reconnecting) return;
    if (connId != _connId) return;
    _reconnecting = true;
    final old = _ws;
    _ws = null;
    unawaited(_subscription?.cancel());
    unawaited(old?.close());
    unawaited(_reconnect(osError));
  }

  Future<void> _reconnect(String osError) async {
    var error = osError;
    for (var attempt = 1; attempt <= reconnectAttempts; attempt++) {
      if (_closing) {
        _reconnecting = false;
        return;
      }
      final delay = math.min(reconnectBackoffSeconds * attempt, reconnectMaxBackoffSeconds);
      engine.host.log(
        'Remote KataGo disconnected ($error); reconnect attempt $attempt/$reconnectAttempts in ${delay.round()}s',
        outputInfo,
      );
      engine.host.setStatus('Reconnecting to remote KataGo (attempt $attempt/$reconnectAttempts)...');
      await sleep(Duration(milliseconds: (delay * 1000).round()));
      if (_closing) {
        _reconnecting = false;
        return;
      }
      WebSocket ws;
      try {
        ws = await connector(remoteUrl);
      } on Object catch (e) {
        error = '$e';
        continue;
      }
      if (_closing) {
        await ws.close();
        _reconnecting = false;
        return;
      }
      _reportedDead = false;
      _attach(ws);
      _reconnecting = false;
      engine.host.log('Reconnected to remote KataGo', outputInfo);
      engine.host.setStatus('Reconnected to remote KataGo.');
      _resendOutstanding();
      return;
    }
    if (!_closing) _reportDead(error, allowPopup: true);
    _reconnecting = false;
  }

  void _resendOutstanding() {
    final payloads = engine.outstandingPayloads();
    if (payloads.isEmpty) return;
    engine.host.log('Re-sending ${payloads.length} outstanding queries after reconnect', outputInfo);
    for (final payload in payloads) {
      final ws = _ws;
      if (ws == null) return;
      try {
        ws.add(payload);
      } on Object catch (e) {
        engine.host.log('Failed to re-send query after reconnect: $e', outputError);
        return;
      }
    }
  }

  void _reportDead(String osError, {required bool allowPopup}) {
    if (_reportedDead) return;
    _reportedDead = true;
    _ws = null;
    engine.onError(
      pyFormat(i18n.tr('Remote KataGo engine disconnected'), {'error': osError}),
      'REMOTE-DISCONNECTED',
      allowPopup: allowPopup,
    );
  }

  /// Waits until every query has its result, while connected.
  Future<void> waitToFinish() async {
    while (_ws != null && !engine.isIdle()) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> shutdown({bool finish = false}) async {
    _closing = true;
    if (finish && _ws != null) await waitToFinish();
    final ws = _ws;
    _ws = null;
    engine.clearSentPayloads();
    await _subscription?.cancel();
    await ws?.close();
  }

  @override
  Future<void> close() => shutdown();

  /// `restart`: drop everything outstanding and connect again.
  Future<bool> restart() async {
    engine.queryGeneration += 1;
    engine.drainPending();
    engine.clearQueries();
    await shutdown();
    return start();
  }
}
