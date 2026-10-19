// Colours, sizes and textures of the board, the evaluation colours and the move tree. The rest of the interface takes
// its colours from the Material colour scheme (ui/app_theme.dart). Colours are given as RGBA lists of 0-1 values;
// [kc] converts them.

import 'dart:ui';

/// A colour from RGBA values between 0 and 1.
Color kc(List<double> rgba) =>
    Color.from(alpha: rgba.length > 3 ? rgba[3] : 1, red: rgba[0], green: rgba[1], blue: rgba[2]);

Color withAlpha(Color c, double alpha) => c.withValues(alpha: alpha);

// basic colors
final white = kc([0.95, 0.95, 0.95, 1]);
final black = kc([0.05, 0.05, 0.05, 1]);
final lightGrey = kc([0.7, 0.7, 0.7, 1]);
final grey = kc([0.5, 0.5, 0.5, 1]);
final lighterGrey = kc([0.85, 0.85, 0.85, 1]);
final red = kc([0.8, 0.1, 0.1, 1]);
final green = kc([0.1, 0.8, 0.1, 1]);
final yellow = kc([0.8, 0.8, 0.1, 1]);
final orange = kc([242 / 255, 96 / 255, 34 / 255, 1]);
final lightOrange = kc([1, 0.5, 0.25, 1]);
final blue = kc([0.3, 0.7, 0.9, 1]);

abstract final class KTheme {
  /// The font of coordinates, move numbers and hint labels on the board.
  static const boardFont = 'Roboto';

  // what the evaluation lines, statistics and toggles are coloured by
  static final scoreColor = blue;
  static final winrateColor = green;
  static final pointlossColor = yellow;
  static final circleTextColors = {'W': black, 'B': white};
  static final statWorseColor = kc([0.8, 0.4, 0.2, 1]);
  static final statBetterColor = kc([0.2, 0.5, 0.1, 1]);

  // textures
  static const stoneTexture = {'B': 'assets/img/B_stone.png', 'W': 'assets/img/W_stone.png'};
  static const evalDotTexture = 'assets/img/dot.png';
  static const lastMoveTexture = 'assets/img/inner.png';
  static const topMoveTexture = 'assets/img/topmove.png';
  static const boardTexture = 'assets/img/board.png';
  static const circleTexture = {'B': 'assets/img/black_circle.png', 'W': 'assets/img/white_circle.png'};

  /// Grid spaces the lines run on past a cut side of the zoomed view.
  static const zoomLineRunOn = 0.5;

  // eval dots
  static final evalColors = {
    'theme:normal': [
      kc([0.447, 0.129, 0.42, 1]),
      kc([0.8, 0, 0, 1]),
      kc([0.9, 0.4, 0.1, 1]),
      kc([0.95, 0.95, 0, 1]),
      kc([0.67, 0.9, 0.18, 1]),
      kc([0.117, 0.588, 0, 1]),
    ],
    'theme:red-green-colourblind': [
      kc([1, 0, 1, 1]),
      kc([1, 0, 0, 1]),
      kc([1, 0.5, 0, 1]),
      kc([1, 1, 0, 1]),
      kc([0, 1, 1, 1]),
      kc([0, 0, 1, 1]),
    ],
  };

  static const evalDotMaxSize = 0.5;
  static const evalDotMinSize = 0.25;

  // board theme
  static final approxBoardColor = kc([0.95, 0.75, 0.47, 1]); // for drawing on top of / hiding what's under it
  static final boardColorTint = kc([1, 1, 1, 1]); // multiplied by texture

  static final hintTextColor = black;

  static final regionBorderColor = kc([64 / 255, 85 / 255, 110 / 255, 1]);
  static final insertBoardColorTint = kc([1, 1, 1, 0.6]);
  static final passCircleColor = kc([0.45, 0.05, 0.45, 0.7]);
  static final passCircleTextColor = kc([0.85, 0.85, 0.85]);

  static final stoneColors = {'B': black, 'W': white};
  static final numberColor = kc([0.85, 0.68, 0.40, 0.8]);

  static final nextMoveDashContrastColors = {'B': lighterGrey, 'W': grey};
  static final pvTextColors = {'W': black, 'B': white}; // numbers in PV

  // board
  static final lineColor = kc([0, 0, 0, 1]);
  static const starpointSize = 0.1;
  static const stoneSize = 0.505; // texture edge is transparent

  static const ghostAlpha = 0.6;
  static const policyAlpha = 0.5;
  static final ownershipColors = {
    'B': kc([0.0, 0.0, 0.10, 0.75]),
    'W': kc([0.92, 0.92, 1.0, 0.800]),
  };
  static const ownershipGamma = 1.33;
  static const stoneMinAlpha = 0.85; // the minimal alpha for dead/weak stones

  static const territoryDisplay = 'blended'; // other possibilities are "marks", "blocks" or "shaded"
  static const blocksThreshold = 0.3;
  static const stoneMarks = 'weak'; // all, none, or weak: marks only on stones likely (>50%) to be captured
  static const markSize = 0.42; // stone mark size as fraction of stone size

  static const hintsLoAlpha = 0.6;
  static const hintsAlpha = 0.8;
  static final topMoveBorderColor = kc([10 / 255, 200 / 255, 250 / 255, 1.0]);
  static const hintScale = 0.98;
  static const uncertainHintScale = 0.7;

  // the engine light: off, busy, ready, pondering
  static final engineDownColor = evalColors['theme:normal']![1];
  static final engineBusyColor = evalColors['theme:normal']![2];
  static final engineReadyColor = evalColors['theme:normal']!.last;
  static final enginePonderingColor = yellow;

  // graph
  static final graphDotColor = kc([0.85, 0.3, 0.3, 1]);
  static final winrateMarkerColor = kc([0.05, 0.7, 0.05, 1]);
  static final scoreMarkerColor = kc([0.2, 0.6, 0.8, 1]);
  static final pointlossMarkerColor = kc([0.7, 0.7, 0.05, 1]);

  // move tree: insert mode, collapsed branches and setup nodes, stone outlines
  static final moveTreeInsertNodeParent = green;
  static final moveTreeInsertCurrent = orange;
  static final moveTreeInsertOther = lightOrange;
  static final moveTreeCollapsed = lightGrey;
  static final moveTreeStoneOutlineColors = {'W': black, 'B': white};
}
