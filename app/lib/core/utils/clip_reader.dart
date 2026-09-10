/// Reads a recorded clip off the device.
///
/// The recorder hands back a filesystem path on mobile and a blob URL on web;
/// the microphone is mobile-only here (see the app README), so the web build
/// only needs this to compile, not to work.
library;

export 'clip_reader_io.dart'
    if (dart.library.js_interop) 'clip_reader_web.dart';
