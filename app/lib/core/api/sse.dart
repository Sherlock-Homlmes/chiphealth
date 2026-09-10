import 'sse_io.dart' if (dart.library.html) 'sse_web.dart' as impl;

/// One server-sent event: the `event:` name and its decoded `data:` payload.
class SseEvent {
  const SseEvent(this.event, this.data);

  final String event;
  final Map<String, dynamic> data;

  @override
  String toString() => 'SseEvent($event, $data)';
}

/// Opens an SSE connection and yields its events until the server closes it.
///
/// Two implementations, because the browser will not let a request set its own
/// headers on a streamed GET: on web this is a native `EventSource` (hence the
/// token in the query string), everywhere else a plain streamed HTTP GET.
Stream<SseEvent> connectSse(Uri uri) => impl.connectSse(uri);
