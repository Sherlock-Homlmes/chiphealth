import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'save_image.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// What the camera hands back: the photo that was reviewed and kept, and the
/// caption written over it (null when left empty).
typedef MomentShot = ({Uint8List bytes, String? caption});

/// The in-app camera for a moment, Locket-style: a square, rounded viewfinder
/// on black, one big shutter, and — once a photo is taken — a review of that
/// same square with the caption written on it before anything is sent.
///
/// Built on the camera plugin rather than the system camera app so the shot
/// is framed exactly as friends will see it, and so review happens here
/// instead of in whatever UI the OS vendor ships.
class MomentCameraScreen extends StatefulWidget {
  const MomentCameraScreen({super.key});

  static Future<MomentShot?> open(BuildContext context) =>
      Navigator.of(context).push<MomentShot>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const MomentCameraScreen(),
        ),
      );

  @override
  State<MomentCameraScreen> createState() => _MomentCameraScreenState();
}

class _MomentCameraScreenState extends State<MomentCameraScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _flashOn = false;

  /// The white screen shown while a flash shot is taken without a hardware
  /// flash to fire — the front camera, a laptop webcam — like Locket's front
  /// flash.
  bool _screenFlash = false;

  /// Why there is no viewfinder, when there is none: no camera, or no
  /// permission.
  String? _error;
  bool _shooting = false;

  /// The photo under review. Non-null switches the screen from viewfinder to
  /// review.
  Uint8List? _shot;
  bool _saving = false;
  final _caption = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _caption.dispose();
    super.dispose();
  }

  /// The OS takes the camera away while the app is in the background; the
  /// controller has to be rebuilt on the way back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller = null;
      controller.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _shot == null) {
      _open(_cameraIndex);
    }
  }

  Future<void> _start() async {
    try {
      _cameras = await availableCameras();
    } catch (_) {
      _cameras = const [];
    }
    if (_cameras.isEmpty) {
      if (mounted)
        setState(() => _error = AppL10n.of(context).khongTimThayCamera);
      return;
    }
    // The back camera first, like the system camera app.
    final back = _cameras.indexWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
    );
    await _open(back < 0 ? 0 : back);
  }

  Future<void> _open(int index) async {
    final old = _controller;
    _controller = null;
    if (mounted) setState(() {});
    await old?.dispose();

    final controller = CameraController(
      _cameras[index],
      // 720p is plenty for a square shown at phone width, and keeps the upload
      // well under the media size limit without re-encoding.
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
    } on CameraException catch (err) {
      await controller.dispose();
      if (!mounted) return;
      setState(
        () => _error = err.code.contains('Access')
            ? AppL10n.of(context).chuaChoPhepDungCameraMo
            : AppL10n.of(context).khongMoDuocCamera,
      );
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _cameraIndex = index;
      _error = null;
    });
    // Off until the shot: the web's only hardware flash is the torch, which
    // would otherwise stay lit the whole time the viewfinder is open.
    try {
      await controller.setFlashMode(FlashMode.off);
    } catch (_) {}
  }

  Future<void> _flip() async {
    if (_cameras.length < 2) return;
    await _open((_cameraIndex + 1) % _cameras.length);
  }

  void _toggleFlash() => setState(() => _flashOn = !_flashOn);

  Future<void> _takePicture() async {
    // Read before the awaits: the strings are localized, and the context may
    // be gone by the time the failure path needs them.
    final l10n = AppL10n.of(context);
    final controller = _controller;
    if (controller == null || _shooting) return;
    setState(() => _shooting = true);

    // The hardware flash when the lens has one (the torch on the web, where
    // "always" is not offered); otherwise the screen lights the face.
    var hardware = false;
    if (_flashOn &&
        controller.description.lensDirection != CameraLensDirection.front) {
      try {
        await controller.setFlashMode(
          kIsWeb ? FlashMode.torch : FlashMode.always,
        );
        hardware = true;
      } catch (_) {}
    }
    if (_flashOn && !hardware) {
      setState(() => _screenFlash = true);
      // Long enough for the sensor's exposure to settle on the white screen.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() => _shot = bytes);
      // Nothing to look at through the viewfinder during review; release the
      // camera so it is not running (and warming the phone) behind the photo.
      _controller = null;
      await controller.dispose();
    } catch (_) {
      if (hardware) {
        try {
          await controller.setFlashMode(FlashMode.off);
        } catch (_) {}
      }
      _toast(l10n.khongChupDuocThuLai);
    } finally {
      if (mounted) {
        setState(() {
          _shooting = false;
          _screenFlash = false;
        });
      }
    }
  }

  Future<void> _retake() async {
    setState(() {
      _shot = null;
      _caption.clear();
    });
    if (_cameras.isNotEmpty) await _open(_cameraIndex);
  }

  Future<void> _save() async {
    final l10n = AppL10n.of(context);
    final shot = _shot;
    if (shot == null || _saving) return;
    setState(() => _saving = true);
    try {
      await saveImage(
        shot,
        filename: 'chiphealth_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      _toast(l10n.daLuuAnhVaoMay);
    } catch (_) {
      _toast(l10n.khongLuuDuocAnhKiemTra);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _send() {
    final shot = _shot;
    if (shot == null) return;
    final caption = _caption.text.trim();
    Navigator.of(
      context,
    ).pop<MomentShot>((bytes: shot, caption: caption.isEmpty ? null : caption));
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final reviewing = _shot != null;
    // While the caption is being typed the keyboard takes the bottom half; the
    // controls step aside so the photo stays above it (the keyboard's own
    // "send" posts).
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Stack(
      children: [
        Scaffold(
          backgroundColor: _Cam.bg,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  children: [
                    _topBar(reviewing),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(44),
                          child: reviewing
                              ? _review()
                              : Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _viewfinder(),
                                    if (_error == null)
                                      Positioned(
                                        top: 14,
                                        right: 14,
                                        child: _flashButton(),
                                      ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                    if (!typing) ...[
                      const SizedBox(height: 40),
                      reviewing ? _reviewControls() : _cameraControls(),
                    ],
                    Spacer(flex: typing ? 1 : 2),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_screenFlash)
          const Positioned.fill(
            child: IgnorePointer(child: ColoredBox(color: Colors.white)),
          ),
      ],
    );
  }

  Widget _topBar(bool reviewing) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
    child: Row(
      children: [
        _RoundButton(
          icon: Icons.close,
          tooltip: AppL10n.of(context).dong,
          onTap: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: Text(
            reviewing
                ? AppL10n.of(context).guiChoBanBe
                : AppL10n.of(context).khoanhKhac,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        // Keeps the title centred against the close button.
        const SizedBox(width: 44),
      ],
    ),
  );

  Widget _viewfinder() {
    final controller = _controller;
    if (_error != null) {
      return Container(
        color: _Cam.surface,
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: _Cam.muted,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _Cam.muted),
            ),
          ],
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        color: _Cam.surface,
        alignment: Alignment.center,
        child: const SizedBox(
          height: 24,
          width: 24,
          child: CircularProgressIndicator(strokeWidth: 2, color: _Cam.muted),
        ),
      );
    }

    // CameraPreview wraps itself in AspectRatio(1 / ratio) while the device is
    // upright (the web reports upright too); giving it that same box and
    // cover-fitting it into the square crops it the way the feed crops the
    // photo.
    final ratio = controller.value.aspectRatio;
    return ColoredBox(
      color: _Cam.surface,
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: 100,
          height: 100 * ratio,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  Widget _review() => Stack(
    fit: StackFit.expand,
    children: [
      Image.memory(_shot!, fit: BoxFit.cover, gaplessPlayback: true),
      // The caption lives on the photo, where friends will read it.
      Positioned(
        left: 20,
        right: 20,
        bottom: 20,
        child: Center(
          child: IntrinsicWidth(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 160),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0x8C000000),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _caption,
                  maxLength: 60,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  cursorColor: Colors.white,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    hintText: AppL10n.of(context).themTinNhan,
                    hintStyle: TextStyle(color: Color(0xB3FFFFFF)),
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );

  /// Over the viewfinder's top-right corner, translucent so the frame still
  /// reads through it.
  Widget _flashButton() => _RoundButton(
    icon: _flashOn ? Icons.flash_on : Icons.flash_off,
    tooltip: _flashOn
        ? AppL10n.of(context).tatFlash
        : AppL10n.of(context).batFlash,
    highlight: _flashOn,
    color: const Color(0x66000000),
    size: 40,
    onTap: (_controller?.value.isInitialized ?? false) ? _toggleFlash : null,
  );

  Widget _cameraControls() {
    final ready = _controller?.value.isInitialized ?? false;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Balances the flip button so the shutter stays centred; the flash
        // sits on the viewfinder.
        const SizedBox(width: 52),
        _Shutter(busy: _shooting, onTap: ready ? _takePicture : null),
        _RoundButton(
          icon: Icons.cameraswitch_outlined,
          tooltip: AppL10n.of(context).doiCamera,
          size: 52,
          onTap: ready && _cameras.length > 1 ? _flip : null,
        ),
      ],
    );
  }

  Widget _reviewControls() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      _RoundButton(
        icon: Icons.close,
        tooltip: AppL10n.of(context).chupLai,
        size: 52,
        onTap: _retake,
      ),
      _SendButton(onTap: _send),
      _RoundButton(
        icon: Icons.download_rounded,
        tooltip: AppL10n.of(context).luuVaoMay,
        size: 52,
        busy: _saving,
        onTap: _save,
      ),
    ],
  );
}

/// The camera is dark whatever the app theme is: a bright frame around the
/// viewfinder fights the photo.
abstract final class _Cam {
  static const bg = Color(0xFF0E0D0C);
  static const surface = Color(0xFF1E1C1A);
  static const button = Color(0xFF2A2724);
  static const muted = Color(0xFF8B8378);
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 44,
    this.highlight = false,
    this.busy = false,
    this.color = _Cam.button,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final bool highlight;
  final bool busy;
  final Color color;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: highlight ? const Color(0xFFFFD54A) : color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: busy ? null : onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    icon,
                    size: size * 0.46,
                    color: highlight
                        ? _Cam.bg
                        : onTap == null
                        ? _Cam.muted
                        : Colors.white,
                  ),
          ),
        ),
      ),
    ),
  );
}

/// The big shutter: an accent ring around a white disc that shrinks while the
/// photo is being taken.
class _Shutter extends StatelessWidget {
  const _Shutter({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: AppL10n.of(context).chup,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: RetroTokens.accent, width: 4),
        ),
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: busy ? 56 : 66,
          height: busy ? 56 : 66,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onTap == null ? _Cam.muted : Colors.white,
          ),
        ),
      ),
    ),
  );
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: AppL10n.of(context).gui,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: 84,
        height: 84,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: RetroTokens.accent,
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.send_rounded, color: Colors.white, size: 36),
      ),
    ),
  );
}
