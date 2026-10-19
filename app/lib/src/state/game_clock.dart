// The game clock: main time, then byo-yomi periods, for the player to move in play mode.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:katrain_core/katrain_core.dart';

import 'sounds.dart';

/// The clock's settings (the `timer` section): main time in minutes, byo-yomi period length in seconds, the number
/// of periods, the minimal time a move should take, and whether it beeps.
typedef ClockSettings = ({double mainTime, double byoLength, int byoPeriods, double minimalUse, bool sound});

class GameClock {
  static const _beepStart = 5.2;

  /// How often [tick] runs, in seconds.
  static const interval = 0.07;

  bool _paused = true;

  /// Seconds left: of main time while there is some, else of the current byo-yomi period.
  double timeRemaining = 30;

  /// Byo-yomi periods left, or null while in main time.
  int? periodsRemaining;

  /// Whether the AI is to move (its time does not run).
  bool ai = false;

  /// The current time; tests give their own.
  final DateTime Function() _now;

  GameNode? _lastNode;
  late DateTime _lastTick = _now();
  bool _beeping = false;

  /// Changes whenever the clock shows something new.
  final ValueNotifier<int> ticks = ValueNotifier(0);

  GameClock({DateTime Function()? now}) : _now = now ?? DateTime.now;

  bool get paused => _paused;
  set paused(bool value) {
    _paused = value;
    ticks.value += 1;
  }

  bool get timeout => periodsRemaining != null && periodsRemaining! <= 0;

  /// Lets time pass for [player] to move at the current node of [game]; [running] when in play mode and no popup
  /// holds the game.
  void tick(Game game, Player player, ClockSettings settings, Sounds sounds, {required bool running}) {
    final node = game.currentNode;
    final now = _now();
    final mainTime = settings.mainTime * 60;
    final byoLength = math.max(1.0, settings.byoLength);
    final byoPeriods = math.max(1, settings.byoPeriods);
    final elapsed = now.difference(_lastTick).inMicroseconds / 1e6;
    final mainRemaining = mainTime - game.mainTimeUsed;
    var beeping = _beeping;
    var usedPeriod = false;
    if (!_paused && !player.ai && running) {
      if (identical(_lastNode, node) && node.children.isEmpty) {
        // main time first; what goes beyond it counts towards the period
        final fromMain = math.max(0.0, math.min(elapsed, mainRemaining));
        game.mainTimeUsed += fromMain;
        node.timeUsed += elapsed - fromMain;
      } else {
        node.timeUsed = 0; // a new position starts a new period
        beeping = false;
      }
      var periodLeft = byoLength - node.timeUsed;
      while (periodLeft < 0 && player.periodsUsed < byoPeriods) {
        node.timeUsed -= byoLength;
        periodLeft += byoLength;
        player.periodsUsed += 1;
        usedPeriod = true;
      }
      if (_beepStart - 2 * interval < periodLeft && periodLeft < _beepStart && player.periodsUsed < byoPeriods) {
        beeping = true;
      } else if (periodLeft > _beepStart) {
        beeping = false;
      }
      final minimalUseAt = byoLength - settings.minimalUse;
      if (settings.minimalUse != 0 &&
          !beeping &&
          (periodLeft - minimalUseAt).abs() < interval &&
          player.periodsUsed < byoPeriods) {
        sounds.play(KThemeSounds.minimumTimePassed, volume: 0.1); // the move may be played now
      }
    } else {
      beeping = false;
    }
    final periodsLeft = byoPeriods - player.periodsUsed;
    if (settings.sound) {
      if (_beeping && !beeping && !usedPeriod) {
        sounds.stop(KThemeSounds.countdown);
      } else if (!_beeping && beeping) {
        sounds.play(KThemeSounds.countdown, volume: periodsLeft > 1 ? 0.5 : 1);
      }
    }
    _lastNode = node;
    _lastTick = now;
    _beeping = beeping;

    final shown = (timeRemaining, periodsRemaining, ai);
    final mainLeft = mainTime - game.mainTimeUsed;
    if (mainLeft > 0) {
      timeRemaining = mainLeft;
      periodsRemaining = null;
    } else {
      timeRemaining = player.periodsUsed == byoPeriods ? 0 : math.max(0, byoLength - node.timeUsed);
      periodsRemaining = math.max(0, periodsLeft);
    }
    ai = player.ai;
    if (shown != (timeRemaining, periodsRemaining, ai)) ticks.value += 1;
  }

  void dispose() => ticks.dispose();
}
