import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';

/// Barcode data is entered by admins only. A miss is a normal state, not an
/// error: the app says "chưa có dữ liệu" and the server records the scan so an
/// admin can add the product later.
class BarcodeScanScreen extends ConsumerStatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  ConsumerState<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends ConsumerState<BarcodeScanScreen> {
  final _controller =
      MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _looking = false;
  String? _scannedCode;
  FoodHit? _found;
  bool _missing = false;
  bool _reporting = false;
  bool _reported = false;
  final _hint = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _hint.dispose();
    super.dispose();
  }

  /// Sends the product name and an optional packaging photo for this barcode.
  Future<void> _report({bool withPhoto = false}) async {
    final code = _scannedCode;
    if (code == null) return;

    setState(() => _reporting = true);
    try {
      String? assetId;
      if (withPhoto) {
        final shot = await ImagePicker().pickImage(
            source: ImageSource.camera, imageQuality: 80, maxWidth: 1400);
        if (shot != null) {
          assetId = await ref.read(mediaRepositoryProvider).upload(
                await shot.readAsBytes(),
                kind: 'meal_photo',
                mimeType: 'image/jpeg',
              );
        }
      }

      await ref.read(nutritionRepositoryProvider).reportBarcode(
            code,
            productNameHint:
                _hint.text.trim().isEmpty ? null : _hint.text.trim(),
            photoAssetId: assetId,
          );
      if (mounted) setState(() => _reported = true);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$err')));
      }
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_looking) return;
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null || code == _scannedCode) return;

    setState(() {
      _looking = true;
      _scannedCode = code;
      _found = null;
      _missing = false;
      _reported = false;
      _hint.clear();
    });

    try {
      final hit = await ref.read(nutritionRepositoryProvider).barcode(code);
      if (!mounted) return;
      setState(() {
        _found = hit;
        _missing = hit == null;
      });
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$err')));
      }
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Quét mã vạch')),
      body: Column(
        children: [
          Expanded(
              child:
                  MobileScanner(controller: _controller, onDetect: _onDetect)),
          if (_scannedCode != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:
                    _missing ? RetroTokens.warnSoft : RetroTokens.paperRaised,
                border: const Border(
                  top: BorderSide(
                      color: RetroTokens.ink, width: RetroTokens.border),
                ),
              ),
              child: PhoneFrame(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_scannedCode!,
                        style: Theme.of(context).textTheme.labelSmall),
                    const SizedBox(height: 6),
                    if (_looking)
                      const LinearProgressIndicator()
                    else if (_found != null) ...[
                      Text(_found!.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      Text(
                        '${Units.kcal(_found!.caloriesKcal)} / ${_found!.servingSizeG.round()} g',
                        style: const TextStyle(color: RetroTokens.inkSoft),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(_found),
                        child: const Text('Thêm vào bữa ăn'),
                      ),
                    ] else if (_missing) ...[
                      const Text('Chưa có dữ liệu cho mã này',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: RetroTokens.warn)),
                      const SizedBox(height: 4),
                      if (_reported)
                        const Text(
                          'Cảm ơn — đã gửi thông tin cho quản trị viên.',
                          style: TextStyle(fontSize: 12, color: RetroTokens.ok),
                        )
                      else ...[
                        const Text(
                          'Đã ghi nhận lượt quét. Cho biết đây là sản phẩm gì để quản trị '
                          'viên bổ sung nhanh hơn:',
                          style: TextStyle(
                              fontSize: 12, color: RetroTokens.inkSoft),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _hint,
                          decoration: const InputDecoration(
                            labelText: 'Tên sản phẩm (tuỳ chọn)',
                            hintText: 'Sữa tươi Vinamilk 180ml',
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _reporting
                                    ? null
                                    : () => _report(withPhoto: true),
                                icon: const Icon(Icons.photo_camera, size: 18),
                                label: const Text('Chụp bao bì'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                onPressed: _reporting ? null : () => _report(),
                                child: _reporting
                                    ? const SizedBox(
                                        height: 16,
                                        width: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white))
                                    : const Text('Gửi'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
