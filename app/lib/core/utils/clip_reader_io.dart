import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readClip(String path) => File(path).readAsBytes();
