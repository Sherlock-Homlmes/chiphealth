import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// What the one "+" can start. Photo, typing and dictation are one entry —
/// they are the same screen, not three ways in. Water is not a meal, but it is
/// the other thing a user reaches for on this screen, so it shares the button
/// rather than forcing a trip back to the home screen.
enum LogMealMethod { meal, barcode, water }

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
        // The options plus the handle can be taller than the sheet's
        // half-screen budget on a short phone, so the list scrolls rather than
        // clipping the last option away.
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
              _option(
                ctx,
                LogMealMethod.meal,
                Icons.photo_camera,
                AppL10n.of(context).ghiBuaAn,
                AppL10n.of(context).chupAnhChonAnhGoHoac,
              ),
              _option(
                ctx,
                LogMealMethod.barcode,
                Icons.qr_code_scanner,
                AppL10n.of(context).quetMaVach,
                AppL10n.of(context).sanPhamDongGoi,
              ),
              const Divider(height: 1, color: RetroTokens.paperSunk),
              _option(
                ctx,
                LogMealMethod.water,
                Icons.local_drink,
                AppL10n.of(context).nuoc,
                AppL10n.of(context).themLuongNuocDaUongHom,
                color: RetroTokens.water,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

Widget _option(
  BuildContext context,
  LogMealMethod method,
  IconData icon,
  String title,
  String subtitle, {
  Color color = RetroTokens.ink,
}) => ListTile(
  leading: Icon(icon, color: color),
  title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
  subtitle: Text(
    subtitle,
    style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
  ),
  onTap: () => Navigator.pop(context, method),
);
