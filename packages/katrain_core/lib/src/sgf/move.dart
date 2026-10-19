// Ported from pysgf (https://github.com/sanderland/pysgf, MIT, (c) 2020 Sander Land), class Move.

/// A move or a placed stone: a player and board coordinates, or a pass when [coords] is null.
///
/// Coordinates are (x, y) with (0, 0) at the bottom left, as in KaTrain. GTP names columns A-T without I and rows
/// from 1 at the bottom; SGF names columns and rows with letters from the top left.
class Move {
  /// GTP column names: A-Z without I, then two-letter names for boards wider than 25.
  static final List<String> gtpCoord = [
    ...'ABCDEFGHJKLMNOPQRSTUVWXYZ'.split(''),
    for (final xa in 'ABCDEFGH'.split(''))
      for (final c in 'ABCDEFGHJKLMNOPQRSTUVWXYZ'.split('')) '$xa$c',
  ];
  static const String players = 'BW';
  static final List<String> sgfCoord = [
    ...'abcdefghijklmnopqrstuvwxyz'.split(''),
    ...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''),
  ];
  static final RegExp _gtpPattern = RegExp(r'([A-Z]+)(\d+)');

  final String player;
  final (int, int)? coords;

  const Move({this.coords, this.player = 'B'});

  /// Parses GTP coordinates such as `D4` or `pass`.
  factory Move.fromGtp(String gtpCoords, {String player = 'B'}) {
    if (gtpCoords.toLowerCase().contains('pass')) {
      return Move(player: player);
    }
    final match = _gtpPattern.matchAsPrefix(gtpCoords);
    if (match == null) {
      throw FormatException('Invalid GTP coordinates: $gtpCoords');
    }
    final x = gtpCoord.indexOf(match[1]!);
    if (x < 0) {
      throw FormatException('Invalid GTP column: ${match[1]}');
    }
    return Move(coords: (x, int.parse(match[2]!) - 1), player: player);
  }

  /// Parses SGF coordinates such as `dd`; empty, or `tt` on boards up to 19x19, is a pass.
  factory Move.fromSgf(String sgfCoords, (int, int) boardSize, {String player = 'B'}) {
    if (sgfCoords.isEmpty || (sgfCoords == 'tt' && boardSize.$1 <= 19 && boardSize.$2 <= 19)) {
      return Move(player: player);
    }
    final x = _sgfIndex(sgfCoords[0]);
    final y = _sgfIndex(sgfCoords[1]);
    return Move(coords: (x, boardSize.$2 - y - 1), player: player);
  }

  static int _sgfIndex(String c) {
    final ix = sgfCoord.indexOf(c);
    if (ix < 0) {
      throw FormatException('Invalid SGF coordinate: $c');
    }
    return ix;
  }

  bool get isPass => coords == null;

  String get opponent => opponentPlayer(player);

  static String opponentPlayer(String? player) => player == 'B' ? 'W' : 'B';

  String gtp() {
    final c = coords;
    if (c == null) return 'pass';
    return '${gtpCoord[c.$1]}${c.$2 + 1}';
  }

  String sgf((int, int) boardSize) {
    final c = coords;
    if (c == null) return '';
    return '${sgfCoord[c.$1]}${sgfCoord[boardSize.$2 - c.$2 - 1]}';
  }

  @override
  bool operator ==(Object other) => other is Move && other.coords == coords && other.player == player;

  @override
  int get hashCode => Object.hash(coords, player);

  @override
  String toString() => 'Move($player${gtp()})';
}
