// Ported from pysgf (https://github.com/sanderland/pysgf, MIT, (c) 2020 Sander Land), class BaseGoGame.

import 'dart:convert';

import 'go_node.dart';
import 'move.dart';

class ParseError implements Exception {
  final String message;
  ParseError(this.message);

  @override
  String toString() => 'ParseError: $message';
}

/// Creates the root or a child node of the tree being parsed.
typedef NodeFactory<N extends BaseGoNode<N>> = N Function({N? parent});

/// Parses SGF, NGF (WBaduk) and GIB (Tygem) game records into trees of [N].
class SgfParser<N extends BaseGoNode<N>> {
  final NodeFactory<N> newNode;

  SgfParser(this.newNode);

  // `\w` in Python matches Unicode word characters; Dart's `\w` is ASCII only, so spell it out
  static final RegExp _propPattern = RegExp(
    r'\s*(?:\(|\)|;|([\p{L}\p{N}_]+)((\s*\[([^\]\\]|\\.)*\])+))',
    unicode: true,
    dotAll: true,
  );
  static final RegExp _sgfPattern = RegExp(r'\(;.*\)', dotAll: true);
  static final RegExp _valueSplit = RegExp(r'\]\s*\[');

  /// Parses a record of the given type: `sgf`, `ngf` or `gib`.
  N parse(String input, {String ext = 'sgf'}) => switch (ext) {
    'sgf' => parseSgf(input),
    'ngf' => parseNgf(input),
    'gib' => parseGib(input),
    _ => throw ParseError('Unsupported file extension: $ext'),
  };

  /// Decodes and parses a file's bytes; [fileName] decides the format and helps choose the encoding.
  ///
  /// pysgf guesses unknown encodings with chardet; here only UTF-8 and Latin-1 are recognised so far, anything else
  /// is read as UTF-8.
  N parseBytes(List<int> bytes, {String fileName = 'game.sgf', String? encoding}) {
    final lower = fileName.toLowerCase();
    final isGib = lower.endsWith('.gib');
    final isNgf = lower.endsWith('.ngf');
    var enc = encoding;
    if (enc == null) {
      if (isGib || isNgf || _contains(bytes, ascii.encode('AP[foxwq]'))) {
        enc = 'utf8';
      } else {
        final match = RegExp(r'CA\[(.*?)\]').firstMatch(latin1.decode(bytes, allowInvalid: true));
        enc = match?[1] ?? 'utf8';
      }
    }
    final ext = isNgf ? 'ngf' : (isGib ? 'gib' : 'sgf');
    return parse(_decodeIgnoringErrors(bytes, enc), ext: ext);
  }

  static bool _contains(List<int> haystack, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// Like Python's `bytes.decode(encoding, errors="ignore")` for the encodings supported so far.
  static String _decodeIgnoringErrors(List<int> bytes, String encoding) {
    final e = encoding.toLowerCase().replaceAll('-', '').replaceAll('_', '');
    if (e == 'latin1' || e == 'iso88591' || e == 'l1') {
      return latin1.decode(bytes, allowInvalid: true);
    }
    return utf8.decode(bytes, allowMalformed: true).replaceAll('�', '');
  }

  // -- SGF

  N parseSgf(String input) {
    final match = _sgfPattern.firstMatch(input);
    final clipped = match?[0] ?? input;
    final root = _parseSgfTree(clipped);
    if ((root.getListProperty('AP') ?? const []).contains('foxwq')) {
      // Fox SGFs carry the wrong komi
      final double correctedKomi;
      if (int.parse(root.getProperty('HA', '0')!.trim()) >= 1) {
        correctedKomi = 0.5;
      } else if (['chinese', 'cn'].contains(root.getProperty('RU', 'japanese')!.toLowerCase())) {
        correctedKomi = 7.5;
      } else {
        correctedKomi = 6.5;
      }
      root.setProperty('KM', correctedKomi);
    }
    return root;
  }

  N _parseSgfTree(String contents) {
    final start = contents.indexOf('(');
    if (start < 0) {
      throw ParseError("Parse error: Expected '(' at start, found ${_head(contents, 0, 50)}");
    }
    final root = newNode();
    final state = _ParseState(contents, start + 1);
    _parseBranch(root, state);
    return root;
  }

  void _parseBranch(N currentMove, _ParseState state) {
    final contents = state.contents;
    var current = currentMove;
    while (state.ix < contents.length) {
      final match = _propPattern.matchAsPrefix(contents, state.ix);
      if (match == null) break;
      state.ix = match.end;
      final item = match[0]!.trim();
      if (item == ')') return;
      if (item == '(') {
        _parseBranch(newNode(parent: current), state);
      } else if (item == ';') {
        // a ';' that is followed only by the final ')' adds no node
        final useless = state.ix < contents.length && _onlyCloseRemains(contents, state.ix);
        if (!(current.empty || useless)) {
          current = newNode(parent: current);
        }
      } else {
        final property = match[1]!;
        final value = match[2]!.trim();
        final values = value.substring(1, value.length - 1).split(_valueSplit);
        current.addListProperty(property, [for (final v in values) BaseGoNode.unescapeValue(v)]);
      }
    }
    if (state.ix < contents.length) {
      throw ParseError('Parse Error: unexpected character at ${_head(contents, state.ix, 25)}');
    }
    throw ParseError("Parse Error: expected ')' at end of input.");
  }

  /// `s[ix:].strip() == ")"` without copying the rest of the input (pysgf does this for every node).
  static bool _onlyCloseRemains(String s, int ix) {
    bool isSpace(int i) => s[i].trim().isEmpty;
    var i = ix;
    while (i < s.length && isSpace(i)) {
      i++;
    }
    if (i >= s.length || s[i] != ')') return false;
    i++;
    while (i < s.length && isSpace(i)) {
      i++;
    }
    return i == s.length;
  }

  static String _head(String s, int from, int length) => s.substring(from, (from + length).clamp(from, s.length));

  // -- NGF

  N parseNgf(String input) {
    final ngf = input.trim();
    final lines = ngf.split('\n');
    int boardSize;
    int handicap;
    String pw;
    String pb;
    String rawDate;
    double komi;
    try {
      boardSize = _pythonInt(lines[1]);
      handicap = _pythonInt(lines[5]);
      pw = _firstWord(lines[2]);
      pb = _firstWord(lines[3]);
      rawDate = lines[8].substring(0, lines[8].length < 8 ? lines[8].length : 8);
      komi = _pythonFloat(lines[7]);
      if (handicap == 0 && komi.truncateToDouble() == komi) komi += 0.5;
    } on RangeError {
      (boardSize, handicap, pw, pb, rawDate, komi) = (19, 0, '', '', '', 0);
    } on FormatException {
      (boardSize, handicap, pw, pb, rawDate, komi) = (19, 0, '', '', '', 0);
    }

    var result = '';
    if (lines.length > 10) {
      if (lines[10].contains('hite win')) {
        result = 'W+';
      } else if (lines[10].contains('lack win')) {
        result = 'B+';
      }
    }

    if (handicap < 0 || handicap > 9) {
      throw ParseError('Handicap $handicap out of range');
    }

    final root = newNode();
    var node = root;
    root.setProperty('SZ', boardSize);
    if (handicap >= 2) {
      root.setProperty('HA', handicap);
      root.placeHandicapStones(handicap, tygem: true);
    }
    if (komi != 0) root.setProperty('KM', komi);
    if (rawDate.length == 8 && RegExp(r'^[0-9]{8}$').hasMatch(rawDate)) {
      root.setProperty('DT', '${rawDate.substring(0, 4)}-${rawDate.substring(4, 6)}-${rawDate.substring(6, 8)}');
    }
    if (pw.isNotEmpty) root.setProperty('PW', pw);
    if (pb.isNotEmpty) root.setProperty('PB', pb);
    if (result.isNotEmpty) root.setProperty('RE', result);

    for (final raw in lines) {
      final line = raw.trim().toUpperCase();
      if (line.length >= 7 && line.substring(0, 2) == 'PM' && (line[4] == 'B' || line[4] == 'W')) {
        final key = line[4];
        final rawMove = line.substring(5, 7).toLowerCase();
        final value = rawMove == 'aa'
            ? ''
            : String.fromCharCode(rawMove.codeUnitAt(0) - 1) + String.fromCharCode(rawMove.codeUnitAt(1) - 1);
        node = newNode(parent: node);
        node.setProperty(key, value);
      }
    }

    if (root.children.isEmpty) throw ParseError('Found no moves');
    return root;
  }

  // -- GIB

  N parseGib(String gib) {
    (String, String) parsePlayerName(String raw) {
      var name = raw;
      var rank = '';
      final parts = raw.split('(');
      if (parts.length == 2 && parts[1].isNotEmpty && parts[1][parts[1].length - 1] == ')') {
        name = parts[0].trim();
        rank = parts[1].substring(0, parts[1].length - 1);
      }
      return (name, rank);
    }

    String makeResult(int grlt, int zipsu) {
      const easyCases = {3: 'B+R', 4: 'W+R', 7: 'B+T', 8: 'W+T'};
      if (easyCases.containsKey(grlt)) return easyCases[grlt]!;
      if (grlt == 0 || grlt == 1) return '${grlt == 0 ? 'B' : 'W'}+${_pyDivTen(zipsu)}';
      return '';
    }

    String getResult(String line, RegExp grltPattern, RegExp zipsuPattern) {
      final grlt = int.tryParse(grltPattern.firstMatch(line)?[1] ?? '');
      final zipsu = int.tryParse(zipsuPattern.firstMatch(line)?[1] ?? '');
      if (grlt == null || zipsu == null) return '';
      return makeResult(grlt, zipsu);
    }

    final root = newNode();
    var node = root;

    for (final raw in gib.split('\n')) {
      final line = raw.trim();
      if (line.startsWith(r'\[GAMEBLACKNAME=') && line.endsWith(r'\]')) {
        final (name, rank) = parsePlayerName(line.substring(16, line.length - 2));
        if (name.isNotEmpty) root.setProperty('PB', name);
        if (rank.isNotEmpty) root.setProperty('BR', rank);
      }
      if (line.startsWith(r'\[GAMEWHITENAME=') && line.endsWith(r'\]')) {
        final (name, rank) = parsePlayerName(line.substring(16, line.length - 2));
        if (name.isNotEmpty) root.setProperty('PW', name);
        if (rank.isNotEmpty) root.setProperty('WR', rank);
      }
      if (line.startsWith(r'\[GAMEINFOMAIN=')) {
        final result = getResult(line, RegExp(r'GRLT:(\d+),'), RegExp(r'ZIPSU:(\d+),'));
        if (result.isNotEmpty) {
          root.setProperty('RE', result);
          final gongje = int.tryParse(RegExp(r'GONGJE:(\d+),').firstMatch(line)?[1] ?? '');
          if (gongje != null && gongje != 0) root.setProperty('KM', gongje / 10);
        }
      }
      if (line.startsWith(r'\[GAMETAG=')) {
        if (!root.properties.containsKey('DT')) {
          final m = RegExp(r'C(\d\d\d\d):(\d\d):(\d\d)').firstMatch(line);
          if (m != null) root.setProperty('DT', '${m[1]}-${m[2]}-${m[3]}');
        }
        if (!root.properties.containsKey('RE')) {
          final result = getResult(line, RegExp(r',W(\d+),'), RegExp(r',Z(\d+),'));
          if (result.isNotEmpty) root.setProperty('RE', result);
        }
        if (!root.properties.containsKey('KM')) {
          final g = int.tryParse(RegExp(r',G(\d+),').firstMatch(line)?[1] ?? '');
          if (g != null && g != 0) root.setProperty('KM', g / 10);
        }
      }
      if (line.startsWith('INI')) {
        if (!identical(node, root)) throw ParseError('Node is not root');
        final setup = line.trim().split(RegExp(r'\s+'));
        final handicap = setup.length > 3 ? int.tryParse(setup[3]) : null;
        if (handicap == null) continue; // truncated or malformed INI line
        if (handicap < 0 || handicap > 9) throw ParseError('Handicap $handicap out of range');
        if (handicap >= 2) {
          root.setProperty('HA', handicap);
          root.placeHandicapStones(handicap, tygem: true);
        }
      }
      if (line.startsWith('STO')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        final int x;
        final int y;
        final String key;
        try {
          key = parts[3] == '1' ? 'B' : 'W';
          x = _pythonInt(parts[4]);
          y = 18 - _pythonInt(parts[5]);
        } on RangeError {
          throw ParseError('Malformed STO line: $line');
        } on FormatException {
          throw ParseError('Malformed STO line: $line');
        }
        if (!(0 <= x && x < 19 && 0 <= y && y < 19)) {
          throw ParseError('Coordinates for move ($x,$y) out of range on line $line');
        }
        node = newNode(parent: node);
        node.setProperty(key, Move(coords: (x, y)).sgf((19, 19)));
      }
    }

    if (root.children.isEmpty) throw ParseError('No valid nodes found');
    return root;
  }

  /// Python's `s.split()[0]`, including the IndexError on a blank line.
  static String _firstWord(String s) {
    final t = s.trim();
    if (t.isEmpty) throw RangeError('list index out of range');
    return t.split(RegExp(r'\s+'))[0];
  }

  static int _pythonInt(String s) {
    final v = int.tryParse(s.trim());
    if (v == null) throw FormatException('invalid literal for int(): $s');
    return v;
  }

  static double _pythonFloat(String s) {
    final v = double.tryParse(s.trim());
    if (v == null) throw FormatException('could not convert string to float: $s');
    return v;
  }

  /// `zipsu / 10` formatted like Python's str() of the float.
  static String _pyDivTen(int zipsu) {
    final v = zipsu / 10;
    return v == v.truncateToDouble() ? '${v.toInt()}.0' : v.toString();
  }
}

class _ParseState {
  final String contents;
  int ix;
  _ParseState(this.contents, this.ix);
}

/// Parser for plain [GoNode] trees.
final goParser = SgfParser<GoNode>(({GoNode? parent}) => GoNode(parent: parent));
