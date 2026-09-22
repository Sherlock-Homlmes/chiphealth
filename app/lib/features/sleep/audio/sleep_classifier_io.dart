import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

import 'sleep_window.dart';

/// YAMNet: MobileNetV1-based audio-event classifier trained on AudioSet, 521
/// output classes. The model bundled at assets/models/yamnet.tflite is the
/// LiteRT build distributed for MediaPipe's audio-classifier task
/// (https://storage.googleapis.com/mediapipe-assets/yamnet_audio_classifier_with_metadata.tflite,
/// 4 126 810 bytes, sha256 10c95ea3eb9a7bb4cb8bddf6feb023250381008177ac162ce169694d05c317de).
/// Verified against yamnet_class_map.csv: input float32[15600] waveform
/// (0.975 s @ 16 kHz), output [1, 521] per-frame sigmoid scores.
///
/// Only a handful of the 521 classes matter here. Indices below were read off
/// the official class map (github.com/tensorflow/models, research/audioset/
/// yamnet/yamnet_class_map.csv) — keep them in sync if the model file is ever
/// swapped for one trained on a different label set.
class _YamnetClassifier implements SleepAudioClassifier {
  _YamnetClassifier(this._interpreter);

  final Interpreter _interpreter;

  // Group members and their thresholds. Snore gets a lower bar than speech:
  // overnight recordings are its whole point, while any speech class firing
  // mid-night is worth hearing about even when unsure.
  //
  //   38 Snoring        41 Snort
  //    0 Speech          2 Conversation     3 Narration      4 Babbling
  //   12 Whispering     13 Laughter        33 Groan         34 Grunt
  //   42 Cough          43 Throat clearing
  //
  // The media group is the veto (see SleepWindowScores.media): everything a
  // speaker in the room produces all night long, rather than a sleeper.
  // Generic "Noise" (507) is deliberately left out — it fires on a person
  // moving around too, and vetoing that would hide real awake minutes.
  //
  //    5 Speech synthesizer   24 Singing        132 Music
  //  133 Musical instrument  262 Background music  263 Theme music
  //  264 Jingle (music)      265 Soundtrack music  514 White noise
  //  518 Television          519 Radio
  static const _snoreClasses = {38, 41};
  static const _talkClasses = {0, 2, 3, 4, 12, 13, 33, 34};
  static const _coughClasses = {42, 43};
  static const _mediaClasses = {
    5,
    24,
    132,
    133,
    262,
    263,
    264,
    265,
    514,
    518,
    519,
  };

  @override
  Future<SleepWindowScores?> classify(Float32List samples) async {
    if (samples.length != 15600) return null;

    final output = [List<double>.filled(521, 0.0)];
    // A flat Float32List matches the [15600] input tensor exactly; the
    // interpreter flattens nested lists itself, so no reshape is needed.
    _interpreter.runForMultipleInputs([samples], {0: output});
    final scores = output[0];

    double maxOf(Set<int> classes) {
      var best = 0.0;
      for (final i in classes) {
        if (scores[i] > best) best = scores[i];
      }
      return best;
    }

    return SleepWindowScores(
      snore: maxOf(_snoreClasses),
      sleepTalk: maxOf(_talkClasses),
      cough: maxOf(_coughClasses),
      media: maxOf(_mediaClasses),
    );
  }
}

/// Loads the model from assets. Null — never an exception — when the asset is
/// missing or the interpreter cannot start, so a broken install degrades to
/// the classifier-less path instead of killing the recorder screen.
Future<SleepAudioClassifier?> createSleepAudioClassifier() async {
  try {
    final interpreter = await Interpreter.fromAsset(
      'assets/models/yamnet.tflite',
    );
    return _YamnetClassifier(interpreter);
  } catch (_) {
    return null;
  }
}
