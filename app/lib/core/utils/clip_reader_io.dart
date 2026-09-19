import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readClip(String path) => File(path).readAsBytes();

/// Best-effort sweep of the temp clip. A stale file in the cache dir is
/// harmless — the OS reclaims it under storage pressure — so a failed delete
/// must never fail the dictation that already succeeded.
Future<void> deleteClip(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } on Exception {
    // Already gone or unwritable; nothing to recover.
    return;
  }
}
