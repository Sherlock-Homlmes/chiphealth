import 'dart:io';

import 'package:audio_session/audio_session.dart';

import 'room_playback.dart';

/// `AudioManager.isMusicActive()` — true while anything holds the STREAM_MUSIC
/// stream, no matter which app owns it or whether it is going to the speaker,
/// a headset or a Bluetooth box. That last part is why this beats echo
/// cancellation on its own: AEC only ever sees what leaves this phone's own
/// speaker, so a podcast on a paired speaker walks straight past it.
class _AndroidPlaybackProbe implements RoomPlaybackProbe {
  final _manager = AndroidAudioManager();

  @override
  Future<bool> isPlaying() async {
    try {
      return await _manager.isMusicActive();
    } catch (_) {
      return false;
    }
  }
}

/// `AVAudioSession.isOtherAudioPlaying` — the recorder's own session is
/// capture-only and mixes with others, so anything this reports belongs to
/// another app.
class _DarwinPlaybackProbe implements RoomPlaybackProbe {
  final _session = AVAudioSession();

  @override
  Future<bool> isPlaying() async {
    try {
      return await _session.isOtherAudioPlaying;
    } catch (_) {
      return false;
    }
  }
}

/// Null on desktop and anywhere the plugin is missing — never an exception,
/// so a platform without an answer records exactly as it did before.
RoomPlaybackProbe? createRoomPlaybackProbe() {
  try {
    if (Platform.isAndroid) return _AndroidPlaybackProbe();
    if (Platform.isIOS) return _DarwinPlaybackProbe();
  } catch (_) {
    // AVAudioSession's constructor throws off iOS; any other plugin trouble
    // lands here too.
  }
  return null;
}
