// The game clock: main time, byo-yomi periods, pausing, the AI's time, and the controller running it only in play
// mode with no dialog open.

import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_core/katrain_core.dart';
import 'package:katrain_neo/src/state/app_controller.dart';
import 'package:katrain_neo/src/state/game_clock.dart';
import 'package:katrain_neo/src/state/sounds.dart';

import 'support/fake_katago.dart';

/// Records the sounds played and stopped.
class RecordingSounds extends Sounds {
  final List<String> played = [];
  final List<String> stopped = [];

  @override
  void play(String sound, {double volume = 1}) => played.add(sound);

  @override
  void stop(String sound) => stopped.add(sound);
}

void main() {
  late FakeKataGo kata;
  late AppController app;
  late DateTime now;
  late GameClock clock;
  late RecordingSounds sounds;

  const oneMinute = (mainTime: 1.0, byoLength: 30.0, byoPeriods: 3, minimalUse: 0.0, sound: true);
  const byoYomiOnly = (mainTime: 0.0, byoLength: 30.0, byoPeriods: 3, minimalUse: 0.0, sound: true);

  setUp(() async {
    kata = FakeKataGo();
    app = await startApp(kata);
    now = DateTime(2026);
    clock = GameClock(now: () => now)..paused = false;
    sounds = RecordingSounds();
  });

  tearDown(() async {
    await kata.settle(app);
    await app.shutdown();
    app.dispose();
    clock.dispose();
  });

  Player black() => app.playersInfo['B']!;

  /// Lets [seconds] pass, then ticks for Black.
  void wait(double seconds, ClockSettings settings, {bool running = true}) {
    now = now.add(Duration(microseconds: (seconds * 1e6).round()));
    clock.tick(app.game!, black(), settings, sounds, running: running);
  }

  test('main time runs down first, without periods', () {
    wait(0, oneMinute);
    wait(10, oneMinute);
    expect(clock.timeRemaining, closeTo(50, 1e-6));
    expect(clock.periodsRemaining, isNull);
  });

  test('time beyond the main time counts towards the first period', () {
    wait(0, oneMinute);
    wait(70, oneMinute);
    expect(clock.periodsRemaining, 3);
    expect(clock.timeRemaining, closeTo(20, 1e-6));
  });

  test('then byo-yomi: each period used up is one less, and the last one ends in a timeout', () {
    wait(0, byoYomiOnly);
    wait(20, byoYomiOnly);
    expect(clock.timeRemaining, closeTo(10, 1e-6));
    expect(clock.periodsRemaining, 3);
    wait(15, byoYomiOnly); // 35 s into the period: the first is used up
    expect(clock.periodsRemaining, 2);
    expect(clock.timeRemaining, closeTo(25, 1e-6));
    wait(60, byoYomiOnly);
    expect(clock.periodsRemaining, 0);
    expect(clock.timeout, isTrue);
    expect(clock.timeRemaining, 0);
  });

  test('a new position starts a new period', () async {
    wait(0, byoYomiOnly);
    wait(20, byoYomiOnly);
    await app.play((4, 4));
    await kata.settle(app);
    wait(1, byoYomiOnly);
    expect(clock.timeRemaining, closeTo(30, 1e-6));
  });

  test('no time passes while paused, for the AI, or when not running', () {
    wait(0, oneMinute);
    clock.paused = true;
    wait(10, oneMinute);
    clock.paused = false;
    wait(10, oneMinute, running: false);
    black().update(playerAi, aiDefault);
    wait(10, oneMinute);
    expect(app.game!.mainTimeUsed, 0);
    expect(clock.ai, isTrue);
  });

  test('the countdown beeps in the last seconds of a period and stops on a new move', () async {
    wait(0, byoYomiOnly);
    wait(30 - 5.1, byoYomiOnly);
    expect(sounds.played, [KThemeSounds.countdown]);
    await app.play((4, 4));
    await kata.settle(app);
    wait(GameClock.interval, byoYomiOnly);
    expect(sounds.stopped, [KThemeSounds.countdown]);
  });

  test('the controller runs the clock only in play mode with no dialog open', () async {
    (app.configStore.data['timer'] as Map)['main_time'] = 1;
    expect(app.mode, modePlay);
    app.clock.paused = false;
    app.tickClock();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    app.tickClock();
    final used = app.game!.mainTimeUsed;
    expect(used, greaterThan(0));

    app.popupOpen = true;
    app.tickClock();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    app.tickClock();
    app.popupOpen = false;
    app.selectMode(modeAnalyze);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    app.tickClock();
    expect(app.game!.mainTimeUsed, used);
  });
}
