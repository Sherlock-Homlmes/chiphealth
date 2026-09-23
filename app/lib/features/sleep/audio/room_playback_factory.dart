// Conditional factory: platforms with dart:io can ask the OS what it is
// playing; web cannot and gets null, which leaves the classifier's own media
// veto as the only defence there. Import THIS file, never the platform files.
export 'room_playback_stub.dart' if (dart.library.io) 'room_playback_io.dart';
