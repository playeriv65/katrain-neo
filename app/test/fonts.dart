// The app's fonts for widget tests, which otherwise lay text out in a placeholder font.

import 'dart:io';

import 'package:flutter/services.dart';

/// Loads Roboto (the board's font) and the Material icons; with [systemUi], also the fonts the interface uses on
/// Windows (Segoe UI, and Microsoft YaHei, Yu Gothic and Malgun Gothic for Chinese, Japanese and Korean) when this
/// machine has them, so text takes the room it takes in the app. Without them Roboto stands in for Segoe UI.
/// Returns the families found on this machine.
Future<Set<String>> loadFonts({bool systemUi = false}) async {
  final found = <String>{};
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
  if (!systemUi) return found;
  final windowsFonts = '${Platform.environment['WINDIR'] ?? r'C:\Windows'}${Platform.pathSeparator}Fonts';
  Future<ByteData> file(String path) async => ByteData.sublistView(await File(path).readAsBytes());
  for (final (family, files) in [
    ('Segoe UI', ['segoeui.ttf', 'segoeuib.ttf', 'seguisb.ttf']),
    ('Microsoft YaHei', ['msyh.ttc', 'msyhbd.ttc']),
    ('Yu Gothic', ['YuGothM.ttc', 'YuGothB.ttc']),
    ('Malgun Gothic', ['malgun.ttf', 'malgunbd.ttf']),
  ]) {
    final present = [
      for (final f in files)
        if (File('$windowsFonts${Platform.pathSeparator}$f').existsSync()) '$windowsFonts${Platform.pathSeparator}$f',
    ];
    final loader = FontLoader(family);
    if (present.isNotEmpty) {
      found.add(family);
      for (final f in present) {
        loader.addFont(file(f));
      }
    } else if (family == 'Segoe UI') {
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    } else {
      continue;
    }
    await loader.load();
  }
  return found;
}
