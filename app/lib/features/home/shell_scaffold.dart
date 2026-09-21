import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import 'home_widgets.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// Bottom navigation, a standard mobile tab bar: home and progress on either
/// side of the green "+". Everything that *writes* data hangs off that button —
/// the logging surfaces (bữa ăn, hoạt động, giấc ngủ) plus the way into the
/// community — so the bar stays two tabs wide however many of those there are.
/// The community lives there rather than as a tab of its own because the home
/// screen already carries its feed. Recording and detail screens live outside
/// this shell so nothing competes with them for the screen.
class ShellScaffold extends StatelessWidget {
  const ShellScaffold({super.key, required this.child});

  final Widget child;

  /// Routing only — no label, so it stays const and `_indexFor` needs no
  /// context.
  static const _tabPaths = ['/', '/progress'];

  /// Labels are read per build rather than held in a const list: they change
  /// with the language setting.
  static List<(String, IconData, IconData, String)> _tabs(
    BuildContext context,
  ) => [
    ('/', Icons.home_outlined, Icons.home, AppL10n.of(context).nha),
    (
      '/progress',
      Icons.insert_chart_outlined,
      Icons.insert_chart,
      AppL10n.of(context).tienTrinh,
    ),
  ];

  /// Targets that are their own full screen rather than a tab inside the
  /// shell. They have to be pushed: `go` replaces the current route, so the
  /// screen would open with an empty back stack and a dead back button.
  static const _fullScreen = {'/record'};

  /// What the green "+" opens. Sleep and the assistant have no other entry
  /// point, so they live here.
  static List<(String, IconData, String)> _logOptions(BuildContext context) => [
    ('/nutrition', Icons.restaurant, AppL10n.of(context).buaAn),
    // The feed, not the recorder: its own "+" starts a new activity.
    ('/training', Icons.directions_run, AppL10n.of(context).hoatDong),
    ('/sleep', Icons.bedtime, AppL10n.of(context).giacNgu),
    ('/moments', Icons.groups, AppL10n.of(context).congDong),
    // Chat with the health agent; its writes wait for the user's confirm.
    ('/coach', Icons.smart_toy_outlined, AppL10n.of(context).troLyAi),
  ];

  Future<void> _openLogSheet(BuildContext context) async {
    final path = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (target, icon, label) in _logOptions(context))
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

  /// -1 when the location is a screen the bar does not carry (bữa ăn, giấc
  /// ngủ, cộng đồng, coach, cá nhân): nothing is highlighted rather than the
  /// wrong thing.
  int _indexFor(String location) {
    for (var i = _tabPaths.length - 1; i >= 0; i--) {
      final path = _tabPaths[i];
      if (path == '/' ? location == '/' : location.startsWith(path)) return i;
    }
    return -1;
  }

  static double _bottomInset(BuildContext context) {
    final inset = MediaQuery.viewPaddingOf(context).bottom;
    if (inset == 0) return 2;
    return math.max(inset - 20, 6);
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final index = _indexFor(location);
    final tabs = _tabs(context);

    return Scaffold(
      body: child,
      // A plain edge-to-edge tab bar, the way phones draw one: flush with the
      // bottom edge, a hairline on top instead of a floating card, and the
      // home-indicator inset painted in the bar's own colour so nothing of the
      // body shows through underneath it.
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: RetroTokens.paperRaised,
          border: Border(
            top: BorderSide(color: RetroTokens.ink, width: RetroTokens.border),
          ),
        ),
        // Not a full SafeArea: the system inset (34px on iPhones, more on
        // Android) doubled the bar's height. Keep only enough of it to clear
        // the home indicator / gesture pill.
        child: Padding(
          padding: EdgeInsets.only(bottom: _bottomInset(context)),
          child: SizedBox(
            height: 54,
            child: Row(
              children: [
                Expanded(
                  child: _NavTab(
                    icon: index == 0 ? tabs[0].$3 : tabs[0].$2,
                    label: tabs[0].$4,
                    selected: index == 0,
                    onTap: () => context.go(tabs[0].$1),
                  ),
                ),
                // The one control that writes anything stays a green disc so
                // it keeps standing out from the two that only navigate.
                Expanded(
                  child: Center(
                    child: AddButton(
                      size: 42,
                      icon: Icons.menu,
                      onTap: () => _openLogSheet(context),
                    ),
                  ),
                ),
                Expanded(
                  child: _NavTab(
                    icon: index == 1 ? tabs[1].$3 : tabs[1].$2,
                    label: tabs[1].$4,
                    selected: index == 1,
                    onTap: () => context.go(tabs[1].$1),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
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
  Widget build(BuildContext context) {
    final color = selected ? RetroTokens.accent : RetroTokens.inkSoft;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        containedInkWell: true,
        highlightShape: BoxShape.rectangle,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              decoration: BoxDecoration(
                color: selected ? RetroTokens.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(RetroTokens.radiusPill),
              ),
              child: Icon(icon, size: 22, color: color),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
