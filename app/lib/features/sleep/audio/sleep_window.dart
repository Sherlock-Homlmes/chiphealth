import 'dart:typed_data';

/// Scores for one 0.975 s analysis window, already reduced from YAMNet's 521
/// AudioSet classes to the three event vocabularies the sleep API accepts.
///
/// YAMNet emits independent sigmoids (not a softmax), so several groups can be
/// high at once; the analyzer, not the classifier, decides which one wins.
class SleepWindowScores {
  const SleepWindowScores({
    required this.snore,
    required this.sleepTalk,
    required this.cough,
  });

  final double snore;
  final double sleepTalk;
  final double cough;

  /// Highest group score and its event type, or null when nothing clears its
  /// own threshold. Ties resolve towards the rarer event (talk > cough >
  /// snore) so a mixed window is not swallowed by the usually-loudest snore.
  (String, double)? strongest() {
    const order = ['sleep_talk', 'cough', 'snore'];
    final candidates = {
      'sleep_talk': (sleepTalk, 0.30),
      'cough': (cough, 0.30),
      'snore': (snore, 0.25),
    };
    String? bestType;
    var bestScore = 0.0;
    for (final type in order) {
      final (score, threshold) = candidates[type]!;
      if (score >= threshold && score > bestScore) {
        bestType = type;
        bestScore = score;
      }
    }
    return bestType == null ? null : (bestType, bestScore);
  }
}

/// Consumes 15 600 float32 samples (0.975 s @ 16 kHz mono) — exactly one
/// YAMNet input window — and returns its event scores, or null when the
/// implementation is unavailable (web) or the model failed to load.
abstract class SleepAudioClassifier {
  Future<SleepWindowScores?> classify(Float32List samples);
}
