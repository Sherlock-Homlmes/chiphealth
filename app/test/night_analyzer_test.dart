import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chiphealth/features/sleep/audio/night_analyzer.dart';
import 'package:chiphealth/features/sleep/audio/sleep_window.dart';
import 'package:chiphealth/features/sleep/audio/wav_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

const _snoreWin = SleepWindowScores(snore: 0.6, sleepTalk: 0.05, cough: 0.05);
const _talkWin = SleepWindowScores(snore: 0.05, sleepTalk: 0.55, cough: 0.05);
const _coughWin = SleepWindowScores(snore: 0.05, sleepTalk: 0.05, cough: 0.6);
const _noneWin = SleepWindowScores(snore: 0.05, sleepTalk: 0.05, cough: 0.05);
// A podcast: the speech group fires exactly as it would for sleep-talking.
const _mediaWin = SleepWindowScores(
  snore: 0.05,
  sleepTalk: 0.55,
  cough: 0.05,
  media: 0.70,
);

/// Scripted classifier: answers in order and counts calls so tests can assert
/// what the silence gate skipped. Only windows above the silence floor ever
/// reach it, so scripts are built loud-window-aligned.
class _FakeClassifier implements SleepAudioClassifier {
  _FakeClassifier(Iterable<SleepWindowScores?> script)
    : _script = List.of(script);

  final List<SleepWindowScores?> _script;
  int calls = 0;

  @override
  Future<SleepWindowScores?> classify(Float32List samples) async {
    final i = calls++;
    return i < _script.length ? _script[i] : _noneWin;
  }
}

const _windowSamples = 15600;

/// One 0.975 s mono int16 LE window. A 160-sample lookup table (one period of
/// a 100 Hz sine at 16 kHz) keeps generating whole nights fast.
Uint8List _pcm(int amplitude, {int sampleCount = _windowSamples}) {
  final lut = List<int>.generate(
    160,
    (i) => (amplitude * math.sin(2 * math.pi * i / 160)).round(),
  );
  final b = ByteData(sampleCount * 2);
  for (var i = 0; i < sampleCount; i++) {
    b.setInt16(i * 2, lut[i % 160], Endian.little);
  }
  return b.buffer.asUint8List();
}

// Amplitudes relative to the analyzer defaults: ~-84 dBFS is far under the
// -45 floor, 3000 reads ~-24 dBFS (snore-loud, still asleep), 6000 reads
// ~-18 dBFS (past the -20 awake line).
const _quietAmp = 3, _loudAmp = 3000, _awakeAmp = 6000;

void main() {
  group('wav encoder', () {
    test('writes a canonical 44-byte PCM header', () {
      final wav = pcm16ToWav(Uint8List.fromList([1, 0, 2, 0]));
      final d = ByteData.sublistView(wav);

      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(d.getUint32(4, Endian.little), 36 + 4);
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
      expect(d.getUint32(16, Endian.little), 16);
      expect(d.getUint16(20, Endian.little), 1); // PCM
      expect(d.getUint16(22, Endian.little), 1); // mono
      expect(d.getUint32(24, Endian.little), 16000);
      expect(d.getUint32(28, Endian.little), 32000); // byte rate
      expect(d.getUint16(32, Endian.little), 2); // block align
      expect(d.getUint16(34, Endian.little), 16); // bits per sample
      expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
      expect(d.getUint32(40, Endian.little), 4);
      expect(wav.length, 48);
    });
  });

  group('media veto', () {
    test('a podcast is not sleep-talking', () {
      expect(_talkWin.strongest(), isNotNull);
      expect(_mediaWin.strongest(), isNull);
      expect(_mediaWin.isMedia, isTrue);
    });

    test('snoring still counts with the radio on', () {
      const overMedia = SleepWindowScores(
        snore: 0.6,
        sleepTalk: 0.55,
        cough: 0.05,
        media: 0.70,
      );
      expect(overMedia.strongest(), ('snore', 0.6));
    });

    test('quiet media does not veto a real cough', () {
      const faintMusic = SleepWindowScores(
        snore: 0.05,
        sleepTalk: 0.05,
        cough: 0.6,
        media: 0.20,
      );
      expect(faintMusic.strongest(), ('cough', 0.6));
    });
  });

  group('windowing + silence gate', () {
    test('quiet windows never reach the classifier', () async {
      final fake = _FakeClassifier(const [_snoreWin]);
      final analyzer = NightAnalyzer(startedAt: 0, classifier: fake);

      for (var i = 0; i < 5; i++) {
        analyzer.pushBytes(_pcm(_quietAmp));
      }
      await analyzer.idle;

      expect(fake.calls, 0);
      expect(analyzer.finish().events, isEmpty);
    });

    test('a sample split across chunk boundaries still forms', () async {
      final fake = _FakeClassifier(const [_snoreWin, _snoreWin]);
      final analyzer = NightAnalyzer(startedAt: 0, classifier: fake);

      // One window pushed in odd-sized pieces, then a whole one.
      final window = _pcm(_loudAmp);
      for (var i = 0; i < window.length; i += 7777) {
        analyzer.pushBytes(
          Uint8List.fromList(
            window.sublist(i, math.min(i + 7777, window.length)),
          ),
        );
      }
      analyzer.pushBytes(_pcm(_loudAmp));
      await analyzer.idle;

      expect(fake.calls, 2);
    });
  });

  group('event coalescing', () {
    test(
      'consecutive snore windows merge into one long event with a clip',
      () async {
        final fake = _FakeClassifier(List.filled(10, _snoreWin));
        final analyzer = NightAnalyzer(startedAt: 0, classifier: fake);

        for (var i = 0; i < 10; i++) {
          analyzer.pushBytes(_pcm(_loudAmp));
        }
        for (var i = 0; i < 4; i++) {
          analyzer.pushBytes(_pcm(_quietAmp));
        }
        await analyzer.idle;
        final result = analyzer.finish();

        expect(result.events, hasLength(1));
        final e = result.events.single;
        expect(e.eventType, 'snore');
        expect(e.occurredAt, 0);
        expect(e.durationMs, 10 * 975);
        expect(e.peakDb, closeTo(-23.8, 0.3));
        expect(e.clip, isNotNull);
        // A WAV, not raw PCM.
        expect(String.fromCharCodes(e.clip!.sublist(0, 4)), 'RIFF');
        expect(String.fromCharCodes(e.clip!.sublist(8, 12)), 'WAVE');
        // pre-roll clamped to night start + ten windows + 2 s of tail.
        expect((e.clip!.length - 44) / 32000, closeTo(0.975 * 10 + 2, 0.01));
      },
    );

    test('a different event type interrupts and closes the open one', () async {
      final fake = _FakeClassifier([
        _snoreWin,
        _snoreWin,
        _snoreWin,
        _coughWin,
        _coughWin,
      ]);
      final analyzer = NightAnalyzer(startedAt: 0, classifier: fake);

      for (var i = 0; i < 5; i++) {
        analyzer.pushBytes(_pcm(_loudAmp));
      }
      for (var i = 0; i < 4; i++) {
        analyzer.pushBytes(_pcm(_quietAmp));
      }
      await analyzer.idle;
      final result = analyzer.finish();

      expect(result.events.map((e) => e.eventType).toList(), [
        'snore',
        'cough',
      ]);
      expect(result.events[0].durationMs, 3 * 975);
      expect(result.events[1].durationMs, 2 * 975);
    });

    test('event count respects maxEvents', () async {
      // Loud bursts at windows 0-1, 6-7, 12-13, 18-19; quiet between.
      final script = <SleepWindowScores?>[
        for (var i = 0; i < 20; i++)
          if (i % 6 < 2) _snoreWin,
      ];
      final fake = _FakeClassifier(script);
      final analyzer = NightAnalyzer(
        startedAt: 0,
        classifier: fake,
        maxEvents: 3,
      );

      for (var i = 0; i < 20; i++) {
        analyzer.pushBytes(_pcm(i % 6 < 2 ? _loudAmp : _quietAmp));
      }
      await analyzer.idle;

      expect(analyzer.finish().events.length, 3);
    });

    test('snore clips stop at maxSnoreClips; a talk clip never does', () async {
      // Two snore bursts, then one talk burst, all separated by quiet gaps.
      final fake = _FakeClassifier([
        ...List.filled(2, _snoreWin),
        ...List.filled(2, _snoreWin),
        ...List.filled(2, _talkWin),
      ]);
      final analyzer = NightAnalyzer(
        startedAt: 0,
        classifier: fake,
        maxSnoreClips: 1,
      );

      final pattern = [
        ...List.filled(2, _loudAmp), // snore burst 1 (clip ok)
        ...List.filled(3, _quietAmp),
        ...List.filled(2, _loudAmp), // snore burst 2 (over budget)
        ...List.filled(3, _quietAmp),
        ...List.filled(2, _loudAmp), // talk burst (always budgeted)
        ...List.filled(3, _quietAmp),
      ];
      for (final amp in pattern) {
        analyzer.pushBytes(_pcm(amp));
      }
      await analyzer.idle;
      final result = analyzer.finish();

      expect(result.events.map((e) => e.eventType).toList(), [
        'snore',
        'snore',
        'sleep_talk',
      ]);
      expect(result.events[0].clip, isNotNull);
      expect(result.events[1].clip, isNull);
      expect(result.events[2].clip, isNotNull);
    });
  });

  group('hypnogram', () {
    test(
      'short night or no classifier yields the fallback (null stages)',
      () async {
        final none = NightAnalyzer(startedAt: 0, classifier: null);
        none.pushBytes(_pcm(_loudAmp));
        await none.idle;
        final r = none.finish();
        expect(r.events, isEmpty);
        expect(r.stages, isNull);

        // ~11 classified minutes is under the 30-minute floor.
        final fake = _FakeClassifier(List.filled(700, _noneWin));
        final short = NightAnalyzer(startedAt: 0, classifier: fake);
        for (var i = 0; i < 700; i++) {
          short.pushBytes(_pcm(_loudAmp));
        }
        await short.idle;
        expect(short.finish().stages, isNull);
      },
    );

    test('three-hour night gets prior-shaped stages', () async {
      const nightMinutes = 180;
      final windows = (nightMinutes * 60 / 0.975).floor(); // 11 076

      // Snore burst early-mid night, a talk burst later, and a loud
      // event-free stretch near the end that should read as awake. Talk
      // minutes must be loud too — a quiet window never reaches the
      // classifier, so it could never be scored as speech.
      int ampFor(int minute) {
        if (minute >= 40 && minute < 46) return _loudAmp; // snoring, asleep
        if (minute >= 120 && minute < 126) return _loudAmp; // sleep talk
        if (minute >= 150 && minute < 156) return _awakeAmp; // no events
        return _quietAmp;
      }

      SleepWindowScores? scoreFor(int minute) => (minute >= 40 && minute < 46)
          ? _snoreWin
          : (minute >= 120 && minute < 126)
          ? _talkWin
          : _noneWin;

      final script = <SleepWindowScores?>[
        for (var i = 0; i < windows; i++)
          if (ampFor((i * 975) ~/ 60000) != _quietAmp)
            scoreFor((i * 975) ~/ 60000),
      ];
      final fake = _FakeClassifier(script);
      final analyzer = NightAnalyzer(startedAt: 0, classifier: fake);

      for (var i = 0; i < windows; i++) {
        final minute = (i * 975) ~/ 60000;
        analyzer.pushBytes(_pcm(ampFor(minute)));
      }
      await analyzer.idle;
      expect(fake.calls, script.length);

      final result = analyzer.finish(endedAt: nightMinutes * 60000);
      final stages = result.stages;
      expect(stages, isNotNull);

      var awake = 0, deep = 0, rem = 0, light = 0;
      var deepCenter = 0.0, remCenter = 0.0;
      for (final s in stages!) {
        final sec = s.seconds;
        final centerMin = (s.startedAt + s.endedAt) / 2 / 60000;
        if (s.stage == 'awake') {
          awake += sec;
        } else if (s.stage == 'deep') {
          deep += sec;
          deepCenter += centerMin * sec;
        } else if (s.stage == 'rem') {
          rem += sec;
          remCenter += centerMin * sec;
        } else {
          light += sec;
        }
      }
      final asleep = deep + rem + light;

      // Quotas land near the adult architecture despite the smoothing pass.
      expect(deep / asleep, closeTo(0.18, 0.06));
      expect(rem / asleep, closeTo(0.22, 0.06));
      // The loud event-free stretch read as awake; snore minutes did not.
      expect(awake, greaterThan(4 * 60));
      // Deep leans early, REM leans late.
      expect(deepCenter / deep, lessThan(nightMinutes / 2));
      expect(remCenter / rem, greaterThan(nightMinutes / 2));

      expect(result.events.map((e) => e.eventType), contains('snore'));
      expect(result.events.map((e) => e.eventType), contains('sleep_talk'));
    });

    test('a quiet night is laid out on cycles, not one early block', () async {
      // The bug this pins: with a silent room every minute scored the same on
      // everything but the clock, so the ranking read "earlier is deeper" and
      // handed back one deep block starting at minute zero, then light to
      // morning. A whole night, nothing to hear, nothing else to go on.
      const nightMinutes = 420; // 7 h
      final windows = (nightMinutes * 60 / 0.975).floor();

      final analyzer = NightAnalyzer(
        startedAt: 0,
        classifier: _FakeClassifier(const [_noneWin]),
      );
      // One loud window so the classifier runs at all; the rest is silence.
      analyzer.pushBytes(_pcm(_loudAmp));
      for (var i = 1; i < windows; i++) {
        analyzer.pushBytes(_pcm(_quietAmp));
      }
      await analyzer.idle;

      final stages = analyzer.finish(endedAt: nightMinutes * 60000).stages;
      expect(stages, isNotNull);

      final deeps = stages!.where((s) => s.stage == 'deep').toList();
      final rems = stages.where((s) => s.stage == 'rem').toList();

      // Deep does not start at lights-out, and it is not one block.
      expect(deeps.first.startedAt, greaterThan(10 * 60000));
      expect(deeps.length, greaterThan(1));
      // REM waits for the first cycle to be over, and there is some of it.
      expect(rems, isNotEmpty);
      expect(rems.first.startedAt, greaterThanOrEqualTo(70 * 60000));
      // The two interleave: deep is not all before every REM.
      expect(deeps.last.startedAt, greaterThan(rems.first.startedAt));
    });

    test('a loud room is not a sleepless night', () async {
      // The bug: gates were absolute, so a night under a fan / an air
      // conditioner / a white-noise track sat above the -20 awake line from
      // lights-out to morning and came back as 40 minutes of pure awake with
      // no deep sleep in it. The floor here is ~-18 dBFS for the whole night;
      // nothing ever rises above it, so nothing is awake.
      const nightMinutes = 40;
      final windows = (nightMinutes * 60 / 0.975).floor();

      final analyzer = NightAnalyzer(
        startedAt: 0,
        classifier: _FakeClassifier(const [_noneWin]),
      );
      for (var i = 0; i < windows; i++) {
        analyzer.pushBytes(_pcm(_awakeAmp));
      }
      await analyzer.idle;

      final stages = analyzer.finish(endedAt: nightMinutes * 60000).stages;
      expect(stages, isNotNull);
      expect(stages!.where((s) => s.stage == 'awake'), isEmpty);
      expect(stages.where((s) => s.stage == 'deep'), isNotEmpty);
    });

    test('a loud stretch of media is not an awake stretch', () async {
      // Same six loud minutes as the three-hour night's awake stretch, but
      // scored as media: the phone is playing, its owner is not up.
      const nightMinutes = 60;
      final windows = (nightMinutes * 60 / 0.975).floor();
      bool isMediaMinute(int m) => m >= 30 && m < 36;

      final script = <SleepWindowScores?>[
        for (var i = 0; i < windows; i++)
          if (isMediaMinute((i * 975) ~/ 60000)) _mediaWin,
      ];
      final fake = _FakeClassifier(script);
      final analyzer = NightAnalyzer(startedAt: 0, classifier: fake);

      for (var i = 0; i < windows; i++) {
        final minute = (i * 975) ~/ 60000;
        analyzer.pushBytes(_pcm(isMediaMinute(minute) ? _awakeAmp : _quietAmp));
      }
      await analyzer.idle;

      final result = analyzer.finish(endedAt: nightMinutes * 60000);
      expect(fake.calls, script.length);
      // Vetoed: those windows scored 0.55 on the speech group.
      expect(result.events, isEmpty);
      expect(result.stages, isNotNull);
      expect(result.stages!.where((s) => s.stage == 'awake'), isEmpty);
    });

    test('a half-hour nap gets no REM', () async {
      const napMinutes = 35;
      final windows = (napMinutes * 60 / 0.975).floor();

      final analyzer = NightAnalyzer(
        startedAt: 0,
        classifier: _FakeClassifier(const [_noneWin]),
      );
      analyzer.pushBytes(_pcm(_loudAmp));
      for (var i = 1; i < windows; i++) {
        analyzer.pushBytes(_pcm(_quietAmp));
      }
      await analyzer.idle;

      final stages = analyzer.finish(endedAt: napMinutes * 60000).stages;
      expect(stages, isNotNull);
      // REM takes about seventy minutes to arrive; a nap never gets there.
      expect(stages!.where((s) => s.stage == 'rem'), isEmpty);
      // And nothing is deep in the first ten minutes.
      for (final s in stages.where((s) => s.stage == 'deep')) {
        expect(s.startedAt, greaterThanOrEqualTo(10 * 60000));
      }
    });
  });
}
