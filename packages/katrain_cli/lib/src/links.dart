// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/cli.py: link_to_command.
// URLs are split like Python's urllib.parse.urlparse / parse_qs / unquote (Dart's Uri lowercases the host and
// rejects some inputs Python accepts).

import 'dart:convert';

import 'to_api.dart';

/// A link that cannot be followed (Python's ValueError).
class LinkError implements Exception {
  final String message;
  LinkError(this.message);

  @override
  String toString() => message;
}

/// Maps a link to an API call: `katrain://state/<name>`, `katrain://goto/45`, `katrain://goto?node=n12`,
/// `katrain://variation/v3?step=2&as=branch`,
/// `katrain://pv?from=45&moves=D4,Q16&step=1`, `katrain://analysis?node=45`.
ApiCall linkToCommand(String url) {
  final parsed = _UrlParts.parse(url);
  if (parsed.scheme != 'katrain') throw LinkError('links must start with katrain://');
  final action = parsed.netloc;
  final path = _strip(parsed.path, '/');
  final String? target = path.isEmpty ? null : path;
  final q = _parseQs(parsed.query);
  switch (action) {
    case 'goto':
      return ApiCall('nav.goto', {'node': target ?? q['node']});
    case 'state':
      return ApiCall('state.restore', {'name': unquote(target ?? q['name'] ?? '')});
    case 'variation':
      return ApiCall('variation.show', {'id': target ?? q['id'], 'step': q['step'], 'as': q['as']});
    case 'pv':
      return ApiCall('pv.show', {
        'from': q['from'],
        'moves': q['moves'],
        'candidate': q['candidate'],
        'step': q['step'],
      });
    case 'analysis':
      return ApiCall('analysis.get', {'node': target ?? q['node']});
  }
  throw LinkError("unknown link action '$action'");
}

String _strip(String s, String char) {
  var start = 0, end = s.length;
  while (start < end && s[start] == char) {
    start++;
  }
  while (end > start && s[end - 1] == char) {
    end--;
  }
  return s.substring(start, end);
}

class _UrlParts {
  final String scheme, netloc, path, query;
  _UrlParts(this.scheme, this.netloc, this.path, this.query);

  static final _schemeChars = RegExp(r'^[A-Za-z][A-Za-z0-9+\-.]*$');

  /// urllib.parse.urlsplit (Python 3.13), which urlparse uses for schemes without `;params`.
  factory _UrlParts.parse(String url) {
    var start = 0;
    while (start < url.length && url.codeUnitAt(start) <= 0x20) {
      start++;
    }
    url = url.substring(start).replaceAll(RegExp('[\t\r\n]'), '');
    var scheme = '', netloc = '', query = '';
    final colon = url.indexOf(':');
    if (colon > 0 && _schemeChars.hasMatch(url.substring(0, colon))) {
      scheme = url.substring(0, colon).toLowerCase();
      url = url.substring(colon + 1);
    }
    if (url.startsWith('//')) {
      var end = url.length;
      for (final c in const ['/', '?', '#']) {
        final i = url.indexOf(c, 2);
        if (i >= 0 && i < end) end = i;
      }
      netloc = url.substring(2, end);
      url = url.substring(end);
      if (netloc.contains('[') != netloc.contains(']')) throw LinkError('Invalid IPv6 URL');
    }
    final hash = url.indexOf('#');
    if (hash >= 0) url = url.substring(0, hash);
    final question = url.indexOf('?');
    if (question >= 0) {
      query = url.substring(question + 1);
      url = url.substring(0, question);
    }
    return _UrlParts(scheme, netloc, url, query);
  }
}

/// `{k: v[-1] for k, v in parse_qs(query).items()}`: blank values and pairs without `=` are dropped.
Map<String, String> _parseQs(String query) {
  final result = <String, String>{};
  for (final pair in query.split('&')) {
    if (pair.isEmpty) continue;
    final eq = pair.indexOf('=');
    if (eq < 0) continue;
    final value = pair.substring(eq + 1);
    if (value.isEmpty) continue;
    result[unquote(pair.substring(0, eq).replaceAll('+', ' '))] = unquote(value.replaceAll('+', ' '));
  }
  return result;
}

final _hex = RegExp(r'^[0-9A-Fa-f]{2}$');

/// Python's urllib.parse.unquote: %XX escapes are UTF-8 bytes (invalid sequences become U+FFFD), malformed
/// escapes are kept as they are.
String unquote(String s) {
  if (!s.contains('%')) return s;
  final bytes = <int>[];
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '%' && i + 3 <= s.length && _hex.hasMatch(s.substring(i + 1, i + 3))) {
      bytes.add(int.parse(s.substring(i + 1, i + 3), radix: 16));
      i += 2;
    } else {
      final rune = s.codeUnitAt(i);
      if (rune >= 0xD800 && rune <= 0xDBFF && i + 1 < s.length) {
        bytes.addAll(utf8.encode(s.substring(i, i + 2)));
        i++;
      } else {
        bytes.addAll(utf8.encode(s[i]));
      }
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}
