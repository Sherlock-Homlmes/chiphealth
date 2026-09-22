import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'audio/night_analyzer.dart';
import 'sleep_review_screen.dart';
import 'sleep_screen.dart';
import 'audio/sleep_classifier_factory.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// Night recording for users with no wearable: the phone stays awake,
/// classifies the mic stream on device with YAMNet, and uploads the whole
/// night in one request when the user wakes up — snore/sleep-talk moments as
/// short clips + events, the hypnogram as estimated stages. The stage
/// vocabulary is identical to the wearable path (awake / light / deep / rem)
/// so nothing downstream has to branch.
///
/// Platforms without the classifier (web: no FFI) keep the pre-AI behaviour:
/// a timer, then one light-sleep block, because duration is what the
/// sleep-debt window needs.
///
/// Surviving the locked screen / a backgrounded app is platform plumbing:
/// on iOS the audio background mode (Info.plist) plus an interruption-resume
/// session keep the mic alive; on Android a microphone foreground service
/// (flutter_foreground_task) holds the process and the CPU awake. Neither
/// survives the user swiping the app away — accepted, the morning upload is
/// the contract.
class NightRecorderScreen extends ConsumerStatefulWidget {
  const NightRecorderScreen({super.key});

  @override
  ConsumerState<NightRecorderScreen> createState() =>
      _NightRecorderScreenState();
}

class _NightRecorderScreenState extends ConsumerState<NightRecorderScreen> {
  DateTime? _startedAt;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  bool _saving = false;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _streamSub;
  NightAnalyzer? _analyzer;

  @override
  void dispose() {
    _ticker?.cancel();
    _streamSub?.cancel();
    _recorder?.stop();
    _recorder?.dispose();
    _stopKeepAlive();
    super.dispose();
  }

  /// Android only: the microphone foreground service that keeps the process
  /// (and so the Dart-side analyzer) alive once the screen is off or another
  /// app is in front. `microphone` — not the plugin-default `dataSync`, which
  /// Android 15 kills after 6 hours against a typical 8-hour night.
  ///
  /// A service that fails to start costs only background survival, not the
  /// recording itself, so it degrades silently instead of blocking the night.
  /// `stopWithTask: true` — without it, swiping the app away would leave the
  /// "Đang ghi giấc ngủ" notification running with nothing behind it.
  Future<void> _startKeepAlive() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    // The notification's wording is read before the permission prompt: after
    // that await this widget may be gone.
    final l10n = AppL10n.of(context);

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sleep_recording',
        channelName: AppL10n.of(context).ghiGiacNguDem,
        channelDescription: AppL10n.of(context).thongBaoGiuChoViecGhi,
        onlyAlertOnce: true,
      ),
      // iOS never reaches startService — the audio session plus the plist's
      // background mode are what keep that platform recording.
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        stopWithTask: true,
      ),
    );

    // Android 13+: without POST_NOTIFICATIONS the service still runs, its
    // notification is just invisible — ask once, ignore the answer.
    await Permission.notification.request();

    await FlutterForegroundTask.startService(
      serviceId: 246,
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: l10n.dangGhiGiacNgu,
      notificationText: l10n.chiphealthVanDangLangNgheCu,
    );
  }

  Future<void> _stopKeepAlive() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // Nothing was started, or the process it lived in is already gone.
    }
  }

  Future<void> _start() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).canQuyenMicroDePhatHien)),
        );
      }
      return;
    }

    // The classifier is null on web or when the model failed to load — the
    // night then degrades to the timer-only fallback instead of failing.
    final classifier = await createSleepAudioClassifier();

    DateTime? streamStarted;
    if (classifier != null) {
      try {
        final started = DateTime.now();
        final analyzer = NightAnalyzer(
          startedAt: started.millisecondsSinceEpoch,
          classifier: classifier,
        );
        final recorder = AudioRecorder();
        await _startKeepAlive();
        // Echo cancellation keeps the phone's own night sounds — white
        // noise, a podcast, a radio alarm — out of the classifier, but the
        // two platforms pay for it very differently.
        //
        // Android's AcousticEchoCanceler attaches to the voice-communication
        // capture path and only touches what the mic records, so it stays on
        // there — with the voice-communication source, which that canceler
        // needs to have something to cancel against.
        //
        // On iOS the same flag switches the input to Apple's voice-processing
        // I/O, which takes over the output path as well and drags everything
        // the phone plays down to call volume for the whole night. Audible
        // beats a marginally cleaner spectrogram, so iOS records the room
        // as it is and the classifier lives with the speaker in the mix.
        final isAndroid = defaultTargetPlatform == TargetPlatform.android;
        final stream = await recorder.startStream(
          RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000, // YAMNet's expected input rate
            numChannels: 1,
            echoCancel: isAndroid,
            // Noise suppression and auto-gain stay off on purpose — they are
            // tuned for speech and would file a snore away as noise, or ride
            // the gain until a quiet room sounds like a loud one.
            noiseSuppress: false,
            autoGain: false,
            androidConfig: const AndroidRecordConfig(
              audioSource: AndroidAudioSource.voiceCommunication,
            ),
            // Resume after interruptions (a call, Siri) instead of pausing for
            // the rest of the night — the record plugin's own background
            // recipe, which requires mixWithOthers for the resume to stick.
            audioInterruption: AudioInterruptionMode.pauseResume,
            // playAndRecord sends playback to the earpiece unless the session
            // asks for the speaker, which is the other half of the "why is
            // everything so quiet" problem. allowBluetooth (HFP/SCO) is left
            // out deliberately: it would drop a paired headset to narrowband
            // call audio. A2DP and AirPlay keep the playback route intact.
            iosConfig: const IosRecordConfig(
              categoryOptions: [
                IosAudioCategoryOption.mixWithOthers,
                IosAudioCategoryOption.defaultToSpeaker,
                IosAudioCategoryOption.allowBluetoothA2DP,
                IosAudioCategoryOption.allowAirPlay,
              ],
            ),
          ),
        );
        // One bad window must not cancel the mic subscription: an exception
        // in an onData handler takes the whole stream down with it.
        _streamSub = stream.listen((chunk) {
          try {
            analyzer.pushBytes(chunk);
          } catch (_) {
            // The night goes on without this window.
          }
        });
        _recorder = recorder;
        _analyzer = analyzer;
        streamStarted = started;
      } catch (err) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$err')));
        }
        await _streamSub?.cancel();
        await _recorder?.dispose();
        await _stopKeepAlive();
        _streamSub = null;
        _recorder = null;
        _analyzer = null;
      }
    }

    setState(() {
      _startedAt = streamStarted ?? DateTime.now();
      _elapsed = Duration.zero;
    });

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _startedAt == null) return;
      setState(() => _elapsed = DateTime.now().difference(_startedAt!));
    });
  }

  Future<void> _stop() async {
    final startedAt = _startedAt;
    final analyzer = _analyzer;
    if (startedAt == null) return;

    _ticker?.cancel();
    setState(() => _saving = true);

    final endedAt = DateTime.now();
    try {
      await _streamSub?.cancel();
      await _recorder?.stop();
      await _recorder?.dispose();
      await _stopKeepAlive();
      _streamSub = null;
      _recorder = null;

      List<SleepStageSegment> stages = _fallbackStages(startedAt, endedAt);
      var eventJson = const <Map<String, dynamic>>[];
      if (analyzer != null) {
        await analyzer.idle; // let in-flight windows finish
        final result = analyzer.finish(endedAt: endedAt.millisecondsSinceEpoch);
        if (result.stages != null) stages = result.stages!;

        // Clips first, so the events can reference their asset ids. A failed
        // clip upload must not lose the event — it just ships without audio.
        final media = ref.read(mediaRepositoryProvider);
        for (final event in result.events) {
          final clip = event.clip;
          if (clip == null) continue;
          try {
            event.audioAssetId = await media.upload(
              clip,
              kind: 'sleep_audio_clip',
              mimeType: 'audio/wav',
            );
          } catch (_) {
            // Event survives without its clip.
          }
        }
        eventJson = result.events.map((e) => e.toJson()).toList();
      }

      final session = await ref
          .read(sleepRepositoryProvider)
          .upload(
            source: 'phone_mic',
            startedAt: startedAt.millisecondsSinceEpoch,
            endedAt: endedAt.millisecondsSinceEpoch,
            stages: stages,
            events: eventJson,
            audioRecordingEnabled: analyzer != null,
          );
      ref.invalidate(sleepDebtProvider);
      // The list the user lands back on has to show the night they just
      // finished, not the one before it.
      ref.invalidate(sleepSessionsProvider);
      ref.invalidate(sleepOnDayProvider);
      ref.invalidate(sleepRangeProvider);
      if (!mounted) return;
      // The night is saved either way; the review is the chance to name it
      // and say something about it, and replaces this screen so the recorder
      // is not sitting behind it.
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => SleepReviewScreen(session: session),
        ),
      );
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
        setState(() => _saving = false);
      }
    }
  }

  /// No classifier / nothing inferred → one light block. The duration is
  /// still what the sleep-debt window needs.
  List<SleepStageSegment> _fallbackStages(DateTime from, DateTime to) => [
    SleepStageSegment(
      stage: 'light',
      startedAt: from.millisecondsSinceEpoch,
      endedAt: to.millisecondsSinceEpoch,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final running = _startedAt != null;
    final analyzer = _analyzer;

    final status = !running
        ? AppL10n.of(context).datMayGanGiuongCamSac
        : analyzer == null
        ? AppL10n.of(context).dangNgheThietBiKhongHo
        : AppL10n.of(context).nightCounts(
            '${analyzer.snoreCount}',
            '${analyzer.talkCount}',
            '${analyzer.coughCount}',
          );

    // Once the night is running there is no way out but "Tôi dậy rồi": a
    // stray back swipe at 3am would throw the whole recording away, and the
    // system back gesture is exactly the kind of thing a sleeping hand finds.
    return PopScope(
      canPop: !running && !_saving,
      child: Scaffold(
        backgroundColor: RetroTokens.ink,
        body: SafeArea(
          child: PhoneFrame(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // No "×" while recording — see the PopScope above.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: running
                        ? const SizedBox(height: 48)
                        : IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: RetroTokens.paper,
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                  ),
                  const Spacer(),
                  Center(
                    child: Column(
                      children: [
                        Text(
                          running
                              ? Units.duration(_elapsed.inSeconds)
                              : AppL10n.of(context).sanSang,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: RetroTokens.paper,
                                fontSize: 48,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          status,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: RetroTokens.inkFaint),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _saving ? null : (running ? _stop : _start),
                    child: Text(
                      _saving
                          ? AppL10n.of(context).dangLuu
                          : (running
                                ? AppL10n.of(context).toiDayRoi
                                : AppL10n.of(context).batDauGhi),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
