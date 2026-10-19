// The sounds of KaTrain (katrain/app/sound.py plays them; theme.py names them).

import 'dart:math' as math;

/// The sound files, relative to the assets folder.
abstract final class KThemeSounds {
  static const stones = [
    'sounds/stone1.wav',
    'sounds/stone2.wav',
    'sounds/stone3.wav',
    'sounds/stone4.wav',
    'sounds/stone5.wav',
  ];
  static const capturing = 'sounds/capturing.wav';
  static const countdown = 'sounds/countdownbeep.wav';
  static const minimumTimePassed = 'sounds/boing.wav';

  static final _random = math.Random();
  static String randomStone() => stones[_random.nextInt(stones.length)];
}

/// Plays and stops sounds; the app gives a real player, tests and headless runs the silent one.
class Sounds {
  const Sounds();
  const Sounds.silent();

  /// KaTrain has no mistake sounds by default (theme.py MISTAKE_SOUNDS).
  List<String> get mistakeSounds => const [];

  void play(String sound, {double volume = 1}) {}

  void stop(String sound) {}
}
