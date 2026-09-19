/// Reads a recorded clip off the device.
///
/// The recorder hands back a filesystem path on mobile and a blob URL on web;
/// both are read back into bytes here. [deleteClip] drops the file afterwards
/// — the clip is only needed in memory for the one transcription request.
library;

export 'clip_reader_io.dart'
    if (dart.library.js_interop) 'clip_reader_web.dart';
