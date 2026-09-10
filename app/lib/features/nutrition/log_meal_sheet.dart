import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// What the one "+" can start. Water is not a meal, but it is the other thing
/// a user reaches for on this screen, so it shares the button rather than
/// forcing a trip back to the home screen.
enum LogMealMethod { photo, barcode, voice, manual, water }

/// Bottom sheet the "+" opens. Kept separate from the screen so the same menu
/// can be raised from anywhere that wants to start an entry.
Future<LogMealMethod?> showLogMealSheet(BuildContext context) =>
    showModalBottomSheet<LogMealMethod>(
      context: context,
      backgroundColor: RetroTokens.paperRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // Same phone-frame width as every screen, so the sheet never stretches
      // edge-to-edge on a tablet.
      constraints: const BoxConstraints(maxWidth: 400),
      builder: (ctx) => SafeArea(
        // Five options plus the handle are taller than the sheet's half-screen
        // budget on a short phone, so the list scrolls rather than clipping the
        // last option away.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                height: 4,
                width: 40,
                decoration: BoxDecoration(
                  color: RetroTokens.paperSunk,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              _option(ctx, LogMealMethod.photo, Icons.photo_camera,
                  'Chụp bữa ăn', 'AI nhận diện từng thành phần'),
              _option(ctx, LogMealMethod.barcode, Icons.qr_code_scanner,
                  'Quét mã vạch', 'Sản phẩm đóng gói'),
              _option(ctx, LogMealMethod.voice, Icons.mic, 'Nói',
                  'Kể bữa ăn, máy tự tách thành phần'),
              _option(ctx, LogMealMethod.manual, Icons.edit_note, 'Nhập tay',
                  'Tìm món có sẵn hoặc tự điền số'),
              const Divider(height: 1, color: RetroTokens.paperSunk),
              _option(ctx, LogMealMethod.water, Icons.local_drink, 'Nước',
                  'Thêm lượng nước đã uống hôm nay',
                  color: RetroTokens.water),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

Widget _option(BuildContext context, LogMealMethod method, IconData icon,
        String title, String subtitle,
        {Color color = RetroTokens.ink}) =>
    ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft)),
      onTap: () => Navigator.pop(context, method),
    );
