// Ported from KaTrain (https://github.com/sanderland/katrain, MIT), katrain/core/base_katrain.py: class Player.

import '../constants.dart';

/// Who plays one colour: a human or an AI, and the mode (normal or teaching) or AI strategy.
class Player {
  final String player;
  String? sgfRank;
  double? calculatedRank;
  String name = '';
  late String playerType;
  late String playerSubtype;
  int periodsUsed;

  Player([
    this.player = 'B',
    String playerType = playerHuman,
    String playerSubtype = playingNormal,
    this.periodsUsed = 0,
  ]) {
    update(playerType, playerSubtype);
  }

  void update([String playerType = playerHuman, String playerSubtype = playingNormal]) {
    this.playerType = playerType;
    this.playerSubtype = playerSubtype;
  }

  bool get ai => playerType == playerAi;

  bool get human => playerType == playerHuman;

  bool get beingTaught => playerType == playerHuman && playerSubtype == playingTeaching;

  String get strategy => ai ? playerSubtype : aiDefault;

  @override
  String toString() => '$playerType ($playerSubtype)';
}
