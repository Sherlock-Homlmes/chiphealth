import 'save_image_io.dart'
    if (dart.library.html) 'save_image_web.dart'
    as impl;

/// Hands the viewer a copy of a photo to keep.
///
/// Two shapes, because the platforms disagree on what "save" is: the browser
/// downloads the file, while on a phone it is written straight into the photo
/// library.
Future<void> saveImage(List<int> bytes, {required String filename}) =>
    impl.saveImage(bytes, filename: filename);
