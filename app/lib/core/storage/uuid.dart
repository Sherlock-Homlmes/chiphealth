import 'dart:math';

/// UUIDv7: 48-bit big-endian millisecond timestamp + random, so ids minted
/// offline still sort chronologically and match the ids the server generates.
String uuidV7([DateTime? at]) {
  final ms = (at ?? DateTime.now()).millisecondsSinceEpoch;
  final rnd = Random.secure();
  final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));

  bytes[0] = (ms >> 40) & 0xFF;
  bytes[1] = (ms >> 32) & 0xFF;
  bytes[2] = (ms >> 24) & 0xFF;
  bytes[3] = (ms >> 16) & 0xFF;
  bytes[4] = (ms >> 8) & 0xFF;
  bytes[5] = ms & 0xFF;

  bytes[6] = (bytes[6] & 0x0F) | 0x70; // version 7
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // RFC 4122 variant

  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}
