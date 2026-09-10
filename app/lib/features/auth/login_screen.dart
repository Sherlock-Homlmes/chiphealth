import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);

    return Scaffold(
      body: SafeArea(
        child: PhoneFrame(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Text(
                  'ChipHealth',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Dinh dưỡng, luyện tập, giấc ngủ — một chỗ, một huấn luyện viên.',
                  style: TextStyle(color: RetroTokens.inkSoft),
                ),
                const Spacer(),
                if (auth.error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: RetroTokens.accentSoft,
                      borderRadius: BorderRadius.circular(RetroTokens.radiusLg),
                      border: Border.all(
                        color: RetroTokens.accent,
                        width: RetroTokens.border,
                      ),
                    ),
                    child: Text(
                      auth.error!,
                      style: const TextStyle(color: RetroTokens.accent),
                    ),
                  ),
                FilledButton(
                  onPressed: auth.loading
                      ? null
                      : () => ref
                            .read(authControllerProvider.notifier)
                            .signInWithGoogle(),
                  child: auth.loading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Đăng nhập bằng Google'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Chỉ dùng Google để đăng nhập. Dữ liệu sức khoẻ đọc trên máy, không gửi token thiết bị đeo lên máy chủ.',
                  style: TextStyle(fontSize: 12, color: RetroTokens.inkFaint),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
