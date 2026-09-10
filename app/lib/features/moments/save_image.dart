import 'save_image_io.dart' if (dart.library.html) 'save_image_web.dart' as impl;

/// Hands the viewer a copy of a photo to keep.
///
/// Two shapes, because the platforms disagree on what "save" is: the browser
/// downloads the file, while on a phone it goes through the system sheet, whose
/// "Save image" is the one path to the camera roll that needs no extra
/// permission and no gallery plugin.
Future<void> saveImage(List<int> bytes, {required String filename}) =>
    impl.saveImage(bytes, filename: filename);
