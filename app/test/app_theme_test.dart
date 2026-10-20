// The colours that carry meaning read in both the light and the dark theme: WCAG contrast of at least 4.5:1 for text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_neo/src/ui/app_theme.dart';

/// The WCAG contrast ratio of two colours.
double contrast(Color a, Color b) {
  final (la, lb) = (a.computeLuminance(), b.computeLuminance());
  return (_max(la, lb) + 0.05) / (la + lb - _max(la, lb) + 0.05);
}

double _max(double a, double b) => a > b ? a : b;

void main() {
  for (final brightness in Brightness.values) {
    group('${brightness.name} theme', () {
      final theme = appTheme(brightness: brightness);
      final scheme = theme.colorScheme;
      final colors = theme.extension<EvalColors>()!;

      test('has its own evaluation colours', () {
        expect(colors, brightness == Brightness.dark ? EvalColors.dark : EvalColors.light);
      });

      for (final (name, color) in [
        ('score', colors.score),
        ('win rate', colors.winrate),
        ('point loss', colors.pointloss),
      ]) {
        test('$name reads on the panels and the background', () {
          for (final background in [scheme.surface, scheme.surfaceContainer, scheme.surfaceContainerHigh]) {
            expect(contrast(color, background), greaterThanOrEqualTo(4.5), reason: '$name on $background');
          }
        });
      }

      test("the report's better and worse bars keep the text on them readable", () {
        for (final bar in [colors.better, colors.worse]) {
          expect(contrast(scheme.onSurface, bar), greaterThanOrEqualTo(4.5), reason: '$bar');
        }
      });
    });
  }

  test('translations on one line: CJK lines join, others get a space', () {
    expect(oneLine('显示\n选点'), '显示选点');
    expect(oneLine('拡大して\n外枠'), '拡大して外枠');
    expect(oneLine('Show\nDots'), 'Show Dots');
    expect(oneLine('Chemin d\'accès de \nl\'exécutable'), 'Chemin d\'accès de l\'exécutable');
    expect(oneLine('KataGo\n分析'), 'KataGo分析');
    expect(oneLine('no break'), 'no break');
  });

  test('text on a colour is black or white, whichever reads', () {
    for (final background in [Colors.yellow, Colors.white, Colors.black, Colors.indigo, const Color(0xFF8B1A1A)]) {
      expect(contrast(textOn(background), background), greaterThanOrEqualTo(4.5), reason: '$background');
    }
  });
}
