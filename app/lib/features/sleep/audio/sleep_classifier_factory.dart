// Conditional factory: on platforms with dart:io the real YAMNet classifier
// loads; everywhere else (web) the stub answers null and the recorder keeps
// its old fallback behaviour. Import THIS file, never the platform files.
export 'sleep_classifier_stub.dart'
    if (dart.library.io) 'sleep_classifier_io.dart';
