// The app shows the main screen for a game (rendered headlessly; no window opens).

import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_neo/src/theme.dart';

void main() {
  test('KaTrain colours convert', () {
    expect(kc([1, 0, 0, 1]).r, 1);
    expect(KTheme.backgroundColor.a, 1);
  });
}
