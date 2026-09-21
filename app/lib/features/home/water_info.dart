import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/tokens.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// The "i" next to the day's water: the total is two numbers added together,
/// and this is where the split is shown.
///
/// Lives on its own so the home card and the diary's summary put the same icon
/// in the same place and open the same breakdown.
class WaterInfoButton extends StatelessWidget {
  const WaterInfoButton({
    super.key,
    required this.drunk,
    required this.fromMeals,
  });

  /// Millilitres the user logged by hand.
  final int drunk;

  /// Millilitres the analysis found in the day's meals.
  final int fromMeals;

  static final _ml = NumberFormat('#,##0');

  @override
  Widget build(BuildContext context) => InkWell(
    customBorder: const CircleBorder(),
    onTap: () => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.of(context).nuocHomNay),
        content: Text(
          AppL10n.of(
            ctx,
          ).waterBreakdown(_ml.format(drunk), _ml.format(fromMeals)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppL10n.of(context).dong),
          ),
        ],
      ),
    ),
    child: const Padding(
      padding: EdgeInsets.all(3),
      child: Icon(Icons.info_outline, size: 15, color: RetroTokens.inkFaint),
    ),
  );
}
