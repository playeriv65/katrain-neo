// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/gui/theme.py: colours, sizes, textures,
// sounds and keyboard shortcuts. KaTrain gives colours as RGBA lists of 0-1 values; [kc] converts them.

import 'dart:ui';

/// A colour from KaTrain's RGBA values between 0 and 1.
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
  // font
  static const defaultFont = 'NotoSansCJKsc';
  static const boardFont = 'Roboto'; // Kivy's default font, which KaTrain draws the board text with
  static const inputFontSize = 20.0; // sp
  static const descFontSize = 18.0; // sp
  static const notesFontSize = 16.0; // sp

  // gui colors
  static final backgroundColor = kc([36 / 255, 48 / 255, 62 / 255, 1]);
  static final boxBackgroundColor = kc([46 / 255, 65 / 255, 88 / 255, 1]);
  static final lighterBackgroundColor = kc([64 / 255, 85 / 255, 110 / 255, 1]);
  static final scrollbarColor = lightGrey;
  static final textColor = white;
  static final scoreColor = blue;
  static final winrateColor = green;
  static final pointlossColor = yellow;
  static final buttonInactiveColor = lightGrey;
  static final buttonBorderColor = white;
  static final buttonTextColor = white;
  static final pauseActiveColor = orange;
  static final timerTextColor = green;
  static final timerTextTimeoutColor = orange;
  static final circleTextColors = {'W': black, 'B': white};
  static final notesTabFontColor = yellow;
  static final infoTabFontColor = white;
  static final errorBorderColor = red;
  static final menuItemFontColor = white;
  static final menuItemShortcutColor = lightGrey;
  static final playAnalyzeTabColor = yellow;
  static final inputFontColor = white;
  static final inputLineColor = kc([1, 1, 1, 0.12]);
  static final inputHintColor = kc([1, 1, 1, 0.5]);
  static final inputErrorColor = kc([0.84, 0, 0, 1]);
  static final rippleColor = kc([0.74, 0.74, 0.74, 1]);
  static final checkboxSelectedColor = kc([0.93, 0.93, 0.93, 1]);
  static final checkboxUnselectedColor = kc([1, 1, 1, 0.7]);
  static final checkboxDisabledColor = kc([1, 1, 1, 0.12]);
  static final mistakeButtonColor = kc([0.79, 0.06, 0.06, 1]);
  static final statWorseColor = kc([0.8, 0.4, 0.2, 1]);
  static final statBetterColor = kc([0.2, 0.5, 0.1, 1]);

  // gui spacing
  static const rightPanelAspectRatio = 0.4; // W/H
  static const controlsPanelAspectRatio = 13.5; // W/H
  static const controlsPanelMinHeight = 50.0;
  static const controlsPanelMaxHeight = 75.0; // dp
  static const cpSpacing = 6.0;
  static const cpSmallSpacing = 3.0;
  static const cpPadding = 6.0;

  // textures
  static const stoneTexture = {'B': 'assets/img/B_stone.png', 'W': 'assets/img/W_stone.png'};
  static const evalDotTexture = 'assets/img/dot.png';
  static const lastMoveTexture = 'assets/img/inner.png';
  static const topMoveTexture = 'assets/img/topmove.png';
  static const boardTexture = 'assets/img/board.png';
  static const graphTexture = 'assets/img/graph_bg.png';
  static const circleTexture = {'B': 'assets/img/black_circle.png', 'W': 'assets/img/white_circle.png'};

  // sounds
  static const stoneSounds = [
    'sounds/stone1.wav',
    'sounds/stone2.wav',
    'sounds/stone3.wav',
    'sounds/stone4.wav',
    'sounds/stone5.wav',
  ];
  static const capturingSound = 'sounds/capturing.wav';
  static const countdownSound = 'sounds/countdownbeep.wav';
  static const minimumTimePassedSound = 'sounds/boing.wav';
  static const mistakeSounds = <String>[];

  // eval dots
  /// Grid spaces the lines run on past a cut side of the zoomed view (playeriv65/katrain fork, gui/zoomview.py).
  static const zoomLineRunOn = 0.5;

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

  static final regionBorderColor = lighterBackgroundColor;
  static final insertBoardColorTint = kc([1, 1, 1, 0.6]);
  static final passCircleColor = kc([0.45, 0.05, 0.45, 0.7]);
  static final passCircleTextColor = kc([0.85, 0.85, 0.85]);

  static final stoneColors = {'B': black, 'W': white};
  static final numberColor = kc([0.85, 0.68, 0.40, 0.8]);

  static final nextMoveDashContrastColors = {'B': lighterGrey, 'W': grey};
  static final outlineColors = {
    'B': kc([0.3, 0.3, 0.3, 0.5]),
    'W': kc([0.7, 0.7, 0.7, 0.5]),
  };
  static final pvTextColors = {'W': black, 'B': white}; // numbers in PV

  // board
  static final lineColor = kc([0, 0, 0, 1]);
  static const starpointSize = 0.1;
  static final boardColor = kc([0.85, 0.68, 0.40, 1]);
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
  static const childScale = 0.95;
  static const hintScale = 0.98;
  static const uncertainHintScale = 0.7;

  // ponder light
  static final engineDownColor = evalColors['theme:normal']![1];
  static final engineBusyColor = evalColors['theme:normal']![2];
  static final engineReadyColor = evalColors['theme:normal']!.last;
  static final enginePonderingColor = yellow;

  // graph
  static final graphDotColor = kc([0.85, 0.3, 0.3, 1]);
  static final winrateMarkerColor = kc([0.05, 0.7, 0.05, 1]);
  static final scoreMarkerColor = kc([0.2, 0.6, 0.8, 1]);
  static final pointlossMarkerColor = kc([0.7, 0.7, 0.05, 1]);

  // move tree
  static final moveTreeLine = lightGrey;
  static final moveTreeCurrent = yellow;
  static final moveTreeSelected = red;
  static final moveTreeInsertNodeParent = green;
  static final moveTreeInsertCurrent = orange;
  static final moveTreeInsertOther = lightOrange;
  static final moveTreeCollapsed = lightGrey;
  static final moveTreeStoneOutlineColors = {'W': black, 'B': white};
}
