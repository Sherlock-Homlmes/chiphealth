import 'dart:typed_data';

import 'package:gal/gal.dart';

/// Straight into the photo library (Photos on iOS, Pictures/ on Android) — no
/// share sheet in between. Gal asks for the add-only permission the first
/// time; a refusal throws, and the caller reports it.
Future<void> saveImage(List<int> bytes, {required String filename}) async {
  if (!await Gal.hasAccess()) {
    await Gal.requestAccess();
  }
  final dot = filename.lastIndexOf('.');
  await Gal.putImageBytes(
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    name: dot > 0 ? filename.substring(0, dot) : filename,
  );
}
