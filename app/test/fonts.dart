// The app's fonts for widget tests, which otherwise lay text out in a placeholder font.

import 'package:flutter/services.dart';

Future<void> loadFonts() async {
  for (final (family, files) in [
    ('Roboto', ['assets/fonts/Roboto-Regular.ttf', 'assets/fonts/Roboto-Bold.ttf']),
    ('MaterialIcons', ['fonts/MaterialIcons-Regular.otf']),
  ]) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(rootBundle.load(f));
    }
    await loader.load();
  }
}
