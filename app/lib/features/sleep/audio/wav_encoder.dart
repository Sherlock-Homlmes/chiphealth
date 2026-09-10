import 'dart:typed_data';

/// Wraps raw mono 16-bit PCM (the format `record` streams) in a RIFF/WAVE
/// header so the clip is a self-contained .wav for R2, playback and Whisper.
///
/// Everything is little-endian per the RIFF spec. A ByteData with the exact
/// final size is allocated once because clips cap at ~15 s (~480 KB) and
/// building them by concatenation would copy the whole buffer per append.
Uint8List pcm16ToWav(
  Uint8List pcm, {
  int sampleRate = 16000,
  int channels = 1,
}) {
  final dataBytes = pcm.length;
  final bytes = ByteData(44 + dataBytes);

  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little); // size of the fmt chunk
  bytes.setUint16(20, 1, Endian.little); // PCM
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * 2, Endian.little); // byte rate
  bytes.setUint16(32, channels * 2, Endian.little); // block align
  bytes.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  bytes.buffer.asUint8List(44, dataBytes).setAll(0, pcm);

  return bytes.buffer.asUint8List();
}
