/// Asks the operating system one question: is this phone playing something
/// right now?
///
/// The mic cannot answer it. YAMNet's media veto catches a song, a TV or a
/// white-noise track because those sound nothing like a sleeper, but a
/// podcast, an audiobook or a bedtime story is speech — the same AudioSet
/// classes sleep-talking fires — and the veto has nothing to grip. The OS,
/// meanwhile, knows exactly whether a stream is running, whatever it sounds
/// like and whichever speaker it comes out of.
abstract class RoomPlaybackProbe {
  /// False on any error: a probe that cannot answer must not silence a real
  /// night of events.
  Future<bool> isPlaying();
}
