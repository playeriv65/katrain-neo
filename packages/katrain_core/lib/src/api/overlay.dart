// Ported from the playeriv65/katrain fork (https://github.com/playeriv65/katrain), katrain/api/overlay.py: the mark
// types and colours of API marks; the app draws them.

import '../game/game_node.dart';
import 'model.dart';

const namedColors = {
  'red': [0.9, 0.15, 0.15],
  'blue': [0.15, 0.4, 0.95],
  'green': [0.1, 0.75, 0.25],
  'yellow': [0.95, 0.85, 0.1],
  'orange': [1.0, 0.55, 0.0],
  'purple': [0.65, 0.25, 0.85],
  'cyan': [0.1, 0.8, 0.85],
  'white': [1.0, 1.0, 1.0],
  'black': [0.0, 0.0, 0.0],
};
const markTypes = ['circle', 'square', 'triangle', 'cross', 'label', 'dot', 'area'];

/// Named colour or #rrggbb -> rgb (0-1); null if not recognised. No colour is red.
List<double>? parseMarkColor(Object? spec) {
  if (spec == null || spec == '' || spec == false) return namedColors['red'];
  final s = '$spec'.trim().toLowerCase();
  if (namedColors.containsKey(s)) return namedColors[s];
  if (s.startsWith('#') && s.length == 7) {
    final parts = [
      for (final i in const [1, 3, 5]) int.tryParse(s.substring(i, i + 2), radix: 16),
    ];
    if (parts.contains(null)) return null;
    return [for (final p in parts) p! / 255];
  }
  return null;
}

/// The marks shown at [current]: its own and the global ones.
List<Map<String, Object?>> visibleMarks(List<Map<String, Object?>> marks, GameNode current) {
  final cur = nodeId(current);
  return [
    for (final m in marks)
      if (m['node'] == null || m['node'] == cur) m,
  ];
}
