import 'dart:typed_data';

// XFile comes from share_plus's own export, so cross_file stays out of the
// pubspec.
import 'package:share_plus/share_plus.dart';

/// The system sheet, where "Save image" writes to the camera roll. Sharing the
/// bytes directly avoids a temp file, and with it path_provider — a dependency
/// this app deliberately does not carry.
Future<void> saveImage(List<int> bytes, {required String filename}) async {
  final file = XFile.fromData(
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    mimeType: 'image/jpeg',
    name: filename,
  );
  await SharePlus.instance.share(
    ShareParams(files: [file], fileNameOverrides: [filename]),
  );
}
