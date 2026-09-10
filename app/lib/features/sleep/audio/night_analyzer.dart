import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/models/models.dart';
import 'sleep_window.dart';
import 'wav_encoder.dart';

/// One overnight audio event, ready for the /sleep/sessions payload once its
/// clip (if any) has been uploaded and the asset id filled in.
class DetectedSleepEvent {
  DetectedSleepEvent({
    required this.eventType,
    required this.occurredAt,
    required this.durationMs,
    required this.peakDb,
    required this.confidence,
    this.clip,
  });

  final String eventType; // snore | sleep_talk | cough
  final int occurredAt; // ms epoch, start of the first active window
  final int durationMs;
  final double peakDb; // loudest window, dBFS
  final double confidence; // best group score seen during the event
  final Uint8List? clip; // complete WAV when a clip was budgeted, else null
  String? audioAssetId;

  Map<String, dynamic> toJson() => {
        'eventType': eventType,
        'occurredAt': occurredAt,
        'durationMs': durationMs,
        'peakDb': peakDb,
        'confidence': confidence,
        if (audioAssetId != null) 'audioAssetId': audioAssetId,
      };
}

class NightAnalyzerResult {
  NightAnalyzerResult({required this.events, required this.stages});

  final List<DetectedSleepEvent> events;

  /// Null when there is nothing honest to build a hypnogram from (night too
  /// short, classifier never ran) — the caller then uploads the plain
  /// one-light-block fallback.
  final List<SleepStageSegment>? stages;
}

class _MinuteStat {
  double dbSum = 0;
  int windows = 0;
  int talkWindows = 0;
  int eventWindows = 0;

  double get meanDb => windows == 0 ? -96 : dbSum / windows;
}

/// Turns a night of streamed mic PCM into events + an estimated hypnogram.
///
/// Pipeline per 0.975 s window (exactly one YAMNet input):
///   bytes -> RMS dBFS -> below the silence floor? -> quiet, no inference
///   (this is the battery saver: most of a night is silence) -> else YAMNet
///   -> group scores -> event coalescing / minute stats.
///
/// Events coalesce while the same type keeps firing; ~3 s of quiet closes one.
/// Clips come from a rolling byte ring: pre-roll before onset, a couple of
/// seconds of tail, hard cap 15 s, and a per-night snore-clip budget so a
/// snorer does not upload a hundred WAVs — sleep_talk and cough are rarer and
/// always keep their clips.
///
/// The hypnogram is prior-shaped, NOT a measurement: without EEG (or at least
/// a heart rate) true REM/deep is unobservable from a phone mic. Loud
/// event-free stretches become awake; the quietest early-night minutes become
/// deep; vocalising late-night minutes become REM; quotas (18% deep / 22% REM)
/// keep the architecture inside the normal adult range. The server already
/// flags phone-mic nights with stages_are_estimated — that flag is the honest
/// contract with the user; this class just makes the estimate plausible.
class NightAnalyzer {
  NightAnalyzer({
    required this.startedAt,
    required this.classifier,
    this.sampleRate = 16000,
    this.silenceFloorDb = -45,
    this.awakeDb = -20,
    this.quietDb = -35,
    this.maxEvents = 80,
    this.maxSnoreClips = 12,
    this.maxClipSeconds = 15,
    this.preRollSeconds = 5,
    this.quietGapWindows = 3,
  });

  final int startedAt; // ms epoch
  final SleepAudioClassifier? classifier;
  final int sampleRate;
  final double silenceFloorDb;
  final double awakeDb;
  final double quietDb;
  final int maxEvents;
  final int maxSnoreClips;
  final int maxClipSeconds;
  final int preRollSeconds;
  final int quietGapWindows;

  static const _windowSamples = 15600; // YAMNet input: 0.975 s @ 16 kHz
  static const _windowMs = 975;
  static const _deepShare = 0.18, _remShare = 0.22;

  final _events = <DetectedSleepEvent>[];
  int _snoreClips = 0;
  final _minutes = <int, _MinuteStat>{};

  // Window accumulator: incoming stream chunks are byte-aligned, not
  // window-aligned, so bytes carry over across chunk boundaries. The window
  // is COPIED before the async classifier sees it — the buffer keeps filling
  // while inference is queued.
  final Float32List _window = Float32List(_windowSamples);
  int _windowFill = 0;
  int _carry = -1; // stray byte of an int16 split across chunks
  int _samplesSeen = 0;
  int _classifiedWindows = 0;

  // Rolling PCM ring for clip extraction.
  final _chunks = ListQueue<Uint8List>();
  final _chunkOffsets = ListQueue<int>();
  int _totalBytes = 0;
  late final int _ringCapacity =
      (preRollSeconds + maxClipSeconds + 2) * sampleRate * 2; // int16 mono

  // Open-event state machine.
  String? _openType;
  int _openStartMs = 0;
  int _openLastEndMs = 0;
  double _openPeakDb = -96;
  double _openConfidence = 0;
  int _openQuietRun = 0;

  /// Classify calls are chained so windows are processed in arrival order even
  /// though each one is async. Tests await this to know the pipeline drained.
  Future<void> _queue = Future.value();
  Future<void> get idle => _queue;

  int get snoreCount => _events.where((e) => e.eventType == 'snore').length;
  int get talkCount =>
      _events.where((e) => e.eventType == 'sleep_talk').length;
  int get coughCount => _events.where((e) => e.eventType == 'cough').length;

  /// Feed one chunk of mono 16-bit little-endian PCM from the record stream.
  void pushBytes(Uint8List chunk) {
    _appendRing(chunk);

    var i = 0;
    if (_carry >= 0 && chunk.isNotEmpty) {
      _pushSample((_carry | (chunk[0] << 8)).toSigned(16));
      _carry = -1;
      i = 1;
    }
    for (; i + 1 < chunk.length; i += 2) {
      _pushSample((chunk[i] | (chunk[i + 1] << 8)).toSigned(16));
    }
    if (i < chunk.length) _carry = chunk[i];
  }

  void _pushSample(int sample) {
    _window[_windowFill++] = sample / 32768.0;
    if (_windowFill == _windowSamples) {
      _windowFill = 0;
      _processWindow(Float32List.fromList(_window));
    }
  }

  /// Computes loudness, gates, and hands loud windows to the classifier.
  void _processWindow(Float32List samples) {
    var sumSq = 0.0;
    for (final s in samples) {
      sumSq += s * s;
    }
    final rms = math.sqrt(sumSq / samples.length);
    // dart:math has no log10; ln/ln10 is the same thing.
    final db = rms == 0 ? -96.0 : 20 * math.log(rms) / math.ln10;

    final firstSample = _samplesSeen;
    _samplesSeen += samples.length;
    final startMs = startedAt + (firstSample * 1000 / sampleRate).round();
    final endMs = startMs + _windowMs;

    final minute = _minutes.putIfAbsent(
        (startMs - startedAt) ~/ 60000, _MinuteStat.new);
    minute.dbSum += db;
    minute.windows++;

    // Everything the state machine sees goes through the same queue — a quiet
    // window's bookkeeping must not overtake an in-flight classification of
    // an earlier window, or event boundaries scramble. Minute stats above are
    // order-independent, so they stay synchronous.
    _queue = _queue.then((_) async {
      if (db < silenceFloorDb || classifier == null) {
        _advanceEvent(null, startMs, endMs, db);
        return;
      }
      final scores = await classifier!.classify(samples);
      _classifiedWindows++;
      final best = scores?.strongest();
      if (best != null) {
        final (type, confidence) = best;
        minute.eventWindows++;
        if (type == 'sleep_talk') minute.talkWindows++;
        _advanceEvent(type, startMs, endMs, db, confidence: confidence);
      } else {
        _advanceEvent(null, startMs, endMs, db);
      }
    });
  }

  /// Feeds the event state machine — synchronously for quiet windows, from
  /// the async chain for classified ones.
  void _advanceEvent(String? type, int startMs, int endMs, double db,
      {double confidence = 0}) {
    if (_openType == null) {
      if (type != null && _events.length < maxEvents) {
        _openType = type;
        _openStartMs = startMs;
        _openLastEndMs = endMs;
        _openPeakDb = db;
        _openConfidence = confidence;
        _openQuietRun = 0;
      }
      return;
    }

    if (type == _openType) {
      _openLastEndMs = endMs;
      if (db > _openPeakDb) _openPeakDb = db;
      if (confidence > _openConfidence) _openConfidence = confidence;
      _openQuietRun = 0;
      return;
    }

    // A different event type interrupts: close what is open, then reopen.
    if (type != null) {
      _closeOpenEvent();
      if (_events.length < maxEvents) {
        _openType = type;
        _openStartMs = startMs;
        _openLastEndMs = endMs;
        _openPeakDb = db;
        _openConfidence = confidence;
        _openQuietRun = 0;
      }
      return;
    }

    if (++_openQuietRun >= quietGapWindows) _closeOpenEvent();
  }

  void _closeOpenEvent() {
    final type = _openType;
    if (type == null) return;

    Uint8List? clip;
    final budgetClip = type != 'snore' || _snoreClips < maxSnoreClips;
    if (budgetClip) {
      // Pre-roll clamps at the night's start; the length cap counts from the
      // effective start, so a leading event is not shortened by pre-roll it
      // never had.
      final clipStartMs =
          math.max(startedAt, _openStartMs - preRollSeconds * 1000);
      var clipEndMs = _openLastEndMs + 2000; // a breath of tail
      clipEndMs = math.min(clipEndMs, clipStartMs + maxClipSeconds * 1000);
      final pcm = _sliceRing(_msToByte(clipStartMs), _msToByte(clipEndMs));
      if (pcm.isNotEmpty) {
        clip = pcm16ToWav(pcm, sampleRate: sampleRate);
        if (type == 'snore') _snoreClips++;
      }
    }

    _events.add(DetectedSleepEvent(
      eventType: type,
      occurredAt: _openStartMs,
      durationMs: _openLastEndMs - _openStartMs,
      peakDb: (_openPeakDb * 10).roundToDouble() / 10,
      confidence: _openConfidence,
      clip: clip,
    ));
    _openType = null;
    _openQuietRun = 0;
  }

  int _msToByte(int ms) => (((ms - startedAt) * sampleRate / 1000) * 2)
      .round()
      .clamp(0, _totalBytes);

  Uint8List _sliceRing(int startByte, int endByte) {
    if (endByte <= startByte) return Uint8List(0);
    final out = BytesBuilder(copy: false);
    final it = _chunks.iterator;
    final offIt = _chunkOffsets.iterator;
    while (it.moveNext() && offIt.moveNext()) {
      final chunkStart = offIt.current;
      final chunkEnd = chunkStart + it.current.length;
      if (chunkEnd <= startByte || chunkStart >= endByte) continue;
      final from = math.max(0, startByte - chunkStart);
      final to = math.min(it.current.length, endByte - chunkStart);
      out.add(it.current.sublist(from, to));
    }
    return out.takeBytes();
  }

  void _appendRing(Uint8List chunk) {
    if (chunk.isEmpty) return;
    // Copy: stream chunks are reused buffers in tests and platform code may
    // recycle them after the listener returns; the ring must own its bytes.
    final owned = Uint8List.fromList(chunk);
    _chunkOffsets.add(_totalBytes);
    _chunks.add(owned);
    _totalBytes += owned.length;
    while (_totalBytes - _chunkOffsets.first > _ringCapacity) {
      _chunks.removeFirst();
      _chunkOffsets.removeFirst();
    }
  }

  /// Closes the night and builds the final events + hypnogram. A partial
  /// trailing window (< 0.975 s) is dropped — it carries no decision.
  NightAnalyzerResult finish({int? endedAt}) {
    _closeOpenEvent();
    final end =
        endedAt ?? startedAt + (_samplesSeen * 1000 / sampleRate).round();
    return NightAnalyzerResult(
      events: List.of(_events),
      stages: _buildStages(end),
    );
  }

  /// Prior-shaped hypnogram — see the class doc. Null when there is nothing
  /// to estimate from.
  List<SleepStageSegment>? _buildStages(int endedMs) {
    final nightMinutes = (endedMs - startedAt) ~/ 60000;
    if (nightMinutes < 30 || _classifiedWindows == 0) return null;

    final stats =
        List.generate(nightMinutes, (m) => _minutes[m] ?? _MinuteStat());
    final labels = List.filled(nightMinutes, 'light');

    // 1) Awake: sustained loud minutes without sleep-event windows (a snoring
    //    minute is asleep even when loud). A lone loud minute is a turn-over.
    var awakeRun = 0;
    for (var m = 0; m < nightMinutes; m++) {
      final s = stats[m];
      final loud = s.meanDb > awakeDb &&
          s.windows > 0 &&
          s.eventWindows * 2 < s.windows;
      if (loud) {
        if (++awakeRun >= 2) {
          labels[m] = 'awake';
          labels[m - 1] = 'awake';
        }
      } else {
        awakeRun = 0;
      }
    }

    // 2) Quotas over the asleep minutes, ranked by circadian-tilted scores:
    //    deep prefers quiet early-night minutes, REM prefers vocalising
    //    late-night ones. REM minutes are picked outside the deep set.
    final asleep = <int>[
      for (var m = 0; m < nightMinutes; m++)
        if (labels[m] != 'awake') m
    ];
    final deepTarget = (asleep.length * _deepShare).round();
    final remTarget = (asleep.length * _remShare).round();

    double u(int m) => nightMinutes == 1 ? 0 : m / (nightMinutes - 1);
    final deepScore = <int, double>{};
    final remScore = <int, double>{};
    for (final m in asleep) {
      final quiet = stats[m].meanDb < quietDb ? 1.0 : 0.2;
      deepScore[m] = quiet * (1 - 0.7 * u(m));
      final talk = (stats[m].talkWindows / 3).clamp(0.0, 1.0);
      remScore[m] = (0.25 + 0.75 * talk) * (0.3 + 0.7 * u(m));
    }

    final byDeep = [...asleep]
      ..sort((a, b) => deepScore[b]!.compareTo(deepScore[a]!));
    final remPool = byDeep.skip(deepTarget).toList()
      ..sort((a, b) => remScore[b]!.compareTo(remScore[a]!));
    for (final m in byDeep.take(deepTarget)) {
      labels[m] = 'deep';
    }
    for (final m in remPool.take(remTarget)) {
      labels[m] = 'rem';
    }

    // 3) Smooth: a 5-minute centred majority kills single-minute flicker,
    //    then runs shorter than 5 minutes fold into their previous neighbour
    //    (the first run folds into the next). SleepStageSegment is immutable,
    //    so the fold works on the label array before segments are built.
    final smoothed = List.of(labels);
    for (var m = 0; m < nightMinutes; m++) {
      var best = 'light';
      var bestVotes = -1;
      for (final cand in ['awake', 'light', 'deep', 'rem']) {
        var votes = 0;
        for (var k = math.max(0, m - 2);
            k <= math.min(nightMinutes - 1, m + 2);
            k++) {
          if (labels[k] == cand) votes++;
        }
        if (votes > bestVotes) {
          bestVotes = votes;
          best = cand;
        }
      }
      smoothed[m] = best;
    }

    final runs = <List<int>>[];
    for (var m = 0; m < nightMinutes; m++) {
      if (runs.isNotEmpty && smoothed[runs.last.last] == smoothed[m]) {
        runs.last.add(m);
      } else {
        runs.add([m]);
      }
    }
    for (var r = 1; r < runs.length; r++) {
      if (runs[r].length < 5) {
        smoothed.fillRange(
            runs[r].first, runs[r].last + 1, smoothed[runs[r - 1].first]);
      }
    }
    if (runs.length > 1 && runs[0].length < 5) {
      smoothed.fillRange(
          runs[0].first, runs[0].last + 1, smoothed[runs[1].first]);
    }

    final segments = <SleepStageSegment>[];
    for (var m = 0; m < nightMinutes; m++) {
      final startMs = startedAt + m * 60000;
      final endMs = math.min(startMs + 60000, endedMs);
      final last = segments.isEmpty ? null : segments.last;
      if (last != null && last.stage == smoothed[m] && last.endedAt == startMs) {
        segments[segments.length - 1] = SleepStageSegment(
            stage: smoothed[m], startedAt: last.startedAt, endedAt: endMs);
      } else {
        segments.add(SleepStageSegment(
            stage: smoothed[m], startedAt: startMs, endedAt: endMs));
      }
    }
    return segments;
  }
}
