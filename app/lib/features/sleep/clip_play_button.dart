// StreamAudioSource is the only way to play bytes already in memory on
// Android/iOS; just_audio marks it experimental.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/providers.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// Play / stop for one snore or sleep-talk clip. The clip is private, so it
/// comes through the API as bytes (bearer token) and is played from memory:
/// a data URI in the browser, a local stream source on the phone.
class ClipPlayButton extends ConsumerStatefulWidget {
  const ClipPlayButton({super.key, required this.assetId});

  final String assetId;

  @override
  ConsumerState<ClipPlayButton> createState() => _ClipPlayButtonState();
}

class _ClipPlayButtonState extends ConsumerState<ClipPlayButton> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _state;
  bool _loading = false;
  bool _playing = false;

  @override
  void dispose() {
    _state?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final player = _player;
    if (_playing && player != null) {
      await player.stop();
      return;
    }
    setState(() => _loading = true);
    try {
      final p = player ?? await _load();
      await p.seek(Duration.zero);
      unawaited(p.play());
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppL10n.of(context).clipPlaybackFailed('$err')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<AudioPlayer> _load() async {
    final bytes = await ref.read(mediaBytesProvider(widget.assetId).future);
    final p = AudioPlayer();
    if (kIsWeb) {
      await p.setUrl(
        Uri.dataFromBytes(bytes, mimeType: 'audio/wav').toString(),
      );
    } else {
      await p.setAudioSource(_BytesSource(bytes));
    }
    _state = p.playerStateStream.listen((s) {
      final playing =
          s.playing && s.processingState != ProcessingState.completed;
      if (mounted && playing != _playing) setState(() => _playing = playing);
      if (s.processingState == ProcessingState.completed) p.pause();
    });
    _player = p;
    return p;
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: _playing ? AppL10n.of(context).dung : AppL10n.of(context).phat,
    onPressed: _loading ? null : _toggle,
    icon: _loading
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(_playing ? Icons.stop : Icons.play_arrow),
  );
}

class _BytesSource extends StreamAudioSource {
  _BytesSource(this.bytes);

  final Uint8List bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = end ?? bytes.length;
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(bytes.sublist(from, to)),
      contentType: 'audio/wav',
    );
  }
}
