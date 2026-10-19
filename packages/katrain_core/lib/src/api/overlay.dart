// The colours of API marks (from the playeriv65/katrain fork's api/overlay.py); the app draws the marks.

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

/// A named colour or #rrggbb as rgb (0-1); null if not recognised.
List<double>? parseMarkColor(String spec) {
  final s = spec.trim().toLowerCase();
  if (namedColors.containsKey(s)) return namedColors[s];
  final hex = RegExp(r'^#([0-9a-f]{6})$').firstMatch(s)?[1];
  if (hex == null) return null;
  return [
    for (final i in const [0, 2, 4]) int.parse(hex.substring(i, i + 2), radix: 16) / 255,
  ];
}
