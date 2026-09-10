import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sse.dart';

/// SSE over a streamed HTTP GET. The response never completes on its own, so
/// the bytes are decoded line by line as they arrive.
Stream<SseEvent> connectSse(Uri uri) async* {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    final response = await request.close();
    if (response.statusCode >= 400) {
      throw HttpException('SSE ${response.statusCode}', uri: uri);
    }

    var event = 'message';
    final data = StringBuffer();

    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      // A blank line ends an event; a leading colon is a comment (the
      // keep-alive) and carries nothing.
      if (line.isEmpty) {
        final payload = data.toString();
        data.clear();
        final name = event;
        event = 'message';
        if (payload.isEmpty) continue;
        yield SseEvent(name, _decode(payload));
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        data.write(line.substring(5).trim());
      }
    }
  } finally {
    client.close(force: true);
  }
}

Map<String, dynamic> _decode(String payload) {
  final decoded = jsonDecode(payload);
  return decoded is Map ? decoded.cast<String, dynamic>() : {'value': decoded};
}
