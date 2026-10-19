// The translations by language, and the fonts some languages need.
// ignore_for_file: lines_longer_than_80_chars

import 'cn.dart';
import 'de.dart';
import 'en.dart';
import 'es.dart';
import 'fr.dart';
import 'jp.dart';
import 'ko.dart';
import 'ru.dart';
import 'tr.dart';
import 'tw.dart';
import 'ua.dart';

/// Translations by language code.
const Map<String, Map<String, String>> translations = {
  'cn': stringsCn,
  'de': stringsDe,
  'en': stringsEn,
  'es': stringsEs,
  'fr': stringsFr,
  'jp': stringsJp,
  'ko': stringsKo,
  'ru': stringsRu,
  'tr': stringsTr,
  'tw': stringsTw,
  'ua': stringsUa,
};

/// Fonts for languages the default font does not cover well.
const Map<String, String> languageFonts = {
  'jp': 'NotoSansJP-Regular.otf',
  'tr': 'NotoSans-Regular.ttf',
  'ua': 'NotoSans-Regular.ttf',
};
