import 'dart:typed_data';
// The browser has no share target for a file the page holds in memory; a
// download is what "save" means here.
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

Future<void> saveImage(List<int> bytes, {required String filename}) async {
  final blob = html.Blob(
      [bytes is Uint8List ? bytes : Uint8List.fromList(bytes)], 'image/jpeg');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = filename
    ..click();
  // Revoked on the next turn of the event loop: the click has to have been
  // handled before the object goes away.
  Future<void>.delayed(const Duration(seconds: 1),
      () => html.Url.revokeObjectUrl(url));
}
