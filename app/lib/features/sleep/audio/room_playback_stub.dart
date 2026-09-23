import 'room_playback.dart';

/// Web has no audio-session plugin surface worth the bytes here. Null keeps
/// the recorder on its previous behaviour rather than failing.
RoomPlaybackProbe? createRoomPlaybackProbe() => null;
