// Sounds through audioplayers: played only when the "timer/sound" setting is on, each file from one cached player,
// restarted when played again.

import 'package:audioplayers/audioplayers.dart';

import 'sounds.dart';

class AudioSounds extends Sounds {
  /// Whether sounds are on (setting `timer/sound`).
  final bool Function() enabled;
  final Map<String, AudioPlayer> _players = {};
  AudioSounds(this.enabled);

  AudioPlayer _player(String sound) =>
      _players.putIfAbsent(sound, () => AudioPlayer()..setReleaseMode(ReleaseMode.stop));

  @override
  void play(String sound, {double volume = 1}) {
    if (!enabled()) return;
    final player = _player(sound);
    player.stop().then((_) => player.play(AssetSource(sound), volume: volume));
  }

  @override
  void stop(String sound) => _players[sound]?.stop();
}
