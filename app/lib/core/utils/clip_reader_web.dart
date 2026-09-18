import 'dart:typed_data';

import 'package:dio/dio.dart';

/// On web the recorder hands back a `blob:` URL; XHR can read it like any
/// other URL, so Dio fetches the bytes without a new dependency.
Future<Uint8List> readClip(String path) async {
  final res = await Dio().get<List<int>>(
    path,
    options: Options(responseType: ResponseType.bytes),
  );
  return Uint8List.fromList(res.data ?? const []);
}
