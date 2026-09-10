import 'dart:async';
import 'dart:convert';
// package:web would need a new direct dependency for one class; this build
// targets dart2js, where dart:html still works.
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'sse.dart';

/// The named events the stream sends. `EventSource` dispatches by name, so
/// each one needs its own listener — an unnamed `onMessage` never sees them.
const _events = ['open', 'reply', 'reaction', 'bye'];

/// SSE in the browser: a native `EventSource`, which reconnects on its own.
Stream<SseEvent> connectSse(Uri uri) {
  late final html.EventSource source;
  late final StreamController<SseEvent> controller;

  controller = StreamController<SseEvent>(
    onListen: () {
      source = html.EventSource(uri.toString());
      for (final name in _events) {
        source.addEventListener(name, (event) {
          final data = (event as html.MessageEvent).data;
          controller.add(SseEvent(name, _decode(data)));
        });
      }
      // The browser retries by itself, so an error is only fatal once the
      // socket is closed for good.
      source.onError.listen((_) {
        if (source.readyState == html.EventSource.CLOSED) {
          controller.close();
        }
      });
    },
    onCancel: () => source.close(),
  );

  return controller.stream;
}

Map<String, dynamic> _decode(Object? raw) {
  if (raw is! String || raw.isEmpty) return const {};
  final decoded = jsonDecode(raw);
  return decoded is Map ? decoded.cast<String, dynamic>() : {'value': decoded};
}
