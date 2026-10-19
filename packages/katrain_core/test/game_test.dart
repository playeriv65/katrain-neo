// Differential tests: the Game port runs the operation script of tools/fixtures/game_fixtures.py and must produce
// the same events and state after every operation.

import 'package:katrain_core/katrain_core.dart';
import 'package:test/test.dart';

import 'fixtures_util.dart';
import 'game_script.dart';

void main() {
  setUpAll(() => i18n.switchLang('en'));
  tearDownAll(() => i18n.switchLang(defaultLanguage));

  test('operation script', () => ScriptRunner(loadFixture('game.json')).check());
}
