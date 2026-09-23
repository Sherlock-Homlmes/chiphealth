import 'dart:typed_data';

/// Scores for one 0.975 s analysis window, already reduced from YAMNet's 521
/// AudioSet classes to the three event vocabularies the sleep API accepts —
/// plus [media], which is not an event but a veto.
///
/// YAMNet emits independent sigmoids (not a softmax), so several groups can be
/// high at once; the analyzer, not the classifier, decides which one wins.
class SleepWindowScores {
  const SleepWindowScores({
    required this.snore,
    required this.sleepTalk,
    required this.cough,
    this.media = 0,
  });

  final double snore;
  final double sleepTalk;
  final double cough;

  /// Music, a podcast, a TV left on, a white-noise track. Nobody's sleep is
  /// in here, but a mic cannot tell a singer from a sleeper and the speech
  /// group fires all night on a podcast. The score exists to cancel the
  /// others, never to produce an event of its own.
  final double media;

  /// Is this window mostly the room's background playback? The analyzer uses
  /// it at minute granularity: a loud minute that is all media is not an
  /// awake minute, it is a minute with the radio on.
  bool get isMedia => media >= 0.50;

  /// Highest group score and its event type, or null when nothing clears its
  /// own threshold. Ties resolve towards the rarer event (talk > cough >
  /// snore) so a mixed window is not swallowed by the usually-loudest snore.
  ///
  /// [media] vetoes before any of that. Sung and spoken media land squarely
  /// in the speech group, so a podcast at 2 a.m. would otherwise be written
  /// down as an hour of sleep-talking; a laugh track does the same to cough.
  /// Snoring is not vetoed — no music scores as a snore, and a night with the
  /// radio on is exactly when the snore count still has to be right.
  ///
  /// [roomPlayback] is the same veto arrived at from outside: the OS saying
  /// this phone is playing something. It exists because [media] only knows
  /// the sounds AudioSet calls media — music, a jingle, a TV, white noise —
  /// and a spoken podcast or audiobook is none of them. To the model it is
  /// speech in a bedroom at 3 a.m., which is the definition of sleep-talking,
  /// and no threshold on [media] can separate the two. What the phone is
  /// playing can.
  (String, double)? strongest({bool roomPlayback = false}) {
    const order = ['sleep_talk', 'cough', 'snore'];
    final mediaOverSpeech =
        roomPlayback || (media >= 0.30 && media >= sleepTalk);
    final candidates = {
      'sleep_talk': (mediaOverSpeech ? 0.0 : sleepTalk, 0.30),
      'cough': (roomPlayback || isMedia ? 0.0 : cough, 0.30),
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
