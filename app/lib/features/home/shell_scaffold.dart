import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import 'home_widgets.dart';

/// Bottom navigation, drawn as one floating pill: home and progress on either
/// side of the green "+". Everything that *writes* data hangs off that button —
/// the logging surfaces (bữa ăn, hoạt động, giấc ngủ) plus the way into the
/// community — so the bar stays two tabs wide however many of those there are.
/// The community lives there rather than as a tab of its own because the home
/// screen already carries its feed. Recording and detail screens live outside
/// this shell so nothing competes with them for the screen.
class ShellScaffold extends StatelessWidget {
  const ShellScaffold({super.key, required this.child});

  final Widget child;

  static const _tabs = [
    ('/', Icons.home_outlined, Icons.home, 'Nhà'),
    (
      '/progress',
      Icons.insert_chart_outlined,
      Icons.insert_chart,
      'Tiến trình',
    ),
  ];

  /// Targets that are their own full screen rather than a tab inside the
  /// shell. They have to be pushed: `go` replaces the current route, so the
  /// screen would open with an empty back stack and a dead back button.
  static const _fullScreen = {'/record'};

  /// What the green "+" opens. Sleep has no other entry point, so it lives here.
  static const _logOptions = [
    ('/nutrition', Icons.restaurant, 'Bữa ăn'),
    ('/record', Icons.directions_run, 'Hoạt động'),
    ('/sleep', Icons.bedtime, 'Giấc ngủ'),
    ('/moments', Icons.groups, 'Cộng đồng'),
  ];

  Future<void> _openLogSheet(BuildContext context) async {
    final path = await showModalBottomSheet<String>(
      context: context,
      // Same phone-frame width as the bar that raised it.
      constraints: const BoxConstraints(maxWidth: 400),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (target, icon, label) in _logOptions)
              ListTile(
                leading: Icon(icon, color: RetroTokens.ink),
                title: Text(label),
                onTap: () => Navigator.of(sheetContext).pop(target),
              ),
          ],
        ),
      ),
    );
    if (path == null || !context.mounted) return;
    if (_fullScreen.contains(path)) {
      await context.push<void>(path);
    } else {
      context.go(path);
    }
  }

  /// -1 when the location is a screen the pill does not carry (bữa ăn, giấc
  /// ngủ, cộng đồng, coach, cá nhân): nothing is highlighted rather than the
  /// wrong thing.
  int _indexFor(String location) {
    for (var i = _tabs.length - 1; i >= 0; i--) {
      final path = _tabs[i].$1;
      if (path == '/' ? location == '/' : location.startsWith(path)) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final index = _indexFor(location);

    return Scaffold(
      body: child,
      // The bar must size itself to its content: a Center (or any other
      // height-unconstrained box) here stretches the bottomNavigationBar to the
      // full screen height and leaves the body with nothing. Align with
      // heightFactor 1 hugs the child's height while still centring it, and
      // passes down the real screen width so the pill can never overflow a
      // narrow phone.
      bottomNavigationBar: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                decoration: BoxDecoration(
                  color: RetroTokens.paperRaised,
                  borderRadius: BorderRadius.circular(RetroTokens.radiusPill),
                  border: Border.all(
                    color: RetroTokens.ink,
                    width: RetroTokens.border,
                  ),
                  boxShadow: const [
                    BoxShadow(color: RetroTokens.ink, offset: Offset(3, 3)),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _NavIcon(
                      icon: index == 0 ? _tabs[0].$3 : _tabs[0].$2,
                      label: _tabs[0].$4,
                      selected: index == 0,
                      onTap: () => context.go(_tabs[0].$1),
                    ),
                    // The same green disc as before, now between the tabs: the
                    // one control that writes anything keeps standing out from
                    // the two that only navigate.
                    AddButton(
                      size: 46,
                      icon: Icons.menu,
                      onTap: () => _openLogSheet(context),
                    ),
                    _NavIcon(
                      icon: index == 1 ? _tabs[1].$3 : _tabs[1].$2,
                      label: _tabs[1].$4,
                      selected: index == 1,
                      onTap: () => context.go(_tabs[1].$1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavIcon extends StatelessWidget {
  const _NavIcon({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: label,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected ? RetroTokens.accentSoft : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 22,
          color: selected ? RetroTokens.accent : RetroTokens.inkSoft,
        ),
      ),
    ),
  );
}
