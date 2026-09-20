import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/nutrition/daily_targets.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import '../moments/moment_tile.dart';
import '../moments/moments_feed.dart';
import 'add_water_sheet.dart';
import 'home_widgets.dart';
import 'water_controller.dart';

/// The day the home screen is reading. Kept as a provider so the week strip and
/// every card below it can never disagree about which date they are showing.
final selectedDayProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

/// Home: one screen per day — energy in/out, macros, water, meals, activity.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _macroPages = PageController();
  int _macroPage = 0;

  @override
  void dispose() {
    _macroPages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final day = ref.watch(selectedDayProvider);
    final iso = Units.localDate(day);
    final isToday = iso == Units.today();
    // Nothing is fetched until the session is restored: the first frame runs
    // before the stored refresh token has been exchanged, so firing the request
    // there only earns a 401 and paints "Missing or invalid token" over the
    // card. The router sends a signed-out user to /login on the same tick.
    final signedIn = ref.watch(authControllerProvider).isSignedIn;
    // The rest of the app watches dailyNutritionProvider(null) for today; using
    // the same key here keeps one cache entry instead of two for the same day.
    final nutrition = signedIn
        ? ref.watch(dailyNutritionProvider(isToday ? null : iso))
        : const AsyncValue<DailyNutrition>.loading();

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: PhoneFrame(
          // Phone-frame layout: the content never stretches past a comfortable
          // reading width on a tablet or a desktop build.
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(dailyNutritionProvider);
              await ref.read(momentsFeedProvider.notifier).refresh();
            },
            // The community feed at the foot of the list pages backwards
            // forever, so the next page is pulled in by how close the list is
            // to its end rather than by a "tải thêm" button.
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                final m = n.metrics;
                if (m.axis == Axis.vertical &&
                    m.pixels > m.maxScrollExtent - 400) {
                  ref.read(momentsFeedProvider.notifier).loadMore();
                }
                return false;
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  const _Header(),
                  const SizedBox(height: 16),
                  _WeekStrip(
                    selected: day,
                    onSelect: (d) =>
                        ref.read(selectedDayProvider.notifier).state = d,
                  ),
                  const SizedBox(height: 16),
                  nutrition.when(
                    loading: () => const _OverviewSkeleton(),
                    error: (err, _) => HomeCard(
                      child: Text(
                        '$err',
                        style: const TextStyle(color: RetroTokens.accent),
                      ),
                    ),
                    data: (daily) => _OverviewCard(
                      daily: daily,
                      controller: _macroPages,
                      page: _macroPage,
                      onPageChanged: (i) => setState(() => _macroPage = i),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _WaterCard(date: iso),
                  const SizedBox(height: 12),
                  _MealsCard(nutrition: nutrition),
                  const SizedBox(height: 12),
                  _ActivityCard(nutrition: nutrition),
                  // Same reason the cards above wait for the session:
                  // watching the feed before the stored token is exchanged
                  // only earns a 401, which would then sit in the card until
                  // a manual pull.
                  if (signedIn) ...[
                    const SizedBox(height: 12),
                    const _CommunityCard(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The community feed, at the foot of the day: what is actually new — a
/// friend's moment this viewer has not opened yet, or anything posted today —
/// with the way into the full feed in the header. Old, already-seen moments
/// belong on the community screen, not on home.
class _CommunityCard extends ConsumerWidget {
  const _CommunityCard();

  /// What belongs on the day the home screen is showing.
  ///
  /// On a past day that is simply the moments posted that day. On today it is
  /// also whatever is still unread, however old — an unopened moment is news
  /// until it has been looked at. Own posts never carry a view row, so they
  /// qualify on the day rule alone.
  static bool _belongsTo(Moment moment, String isoDay, String? myId) {
    final posted = Units.localDate(
      DateTime.fromMillisecondsSinceEpoch(moment.createdAt),
    );
    if (posted == isoDay) return true;
    if (isoDay != Units.today()) return false;
    return moment.userId != myId && !moment.seen;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(momentsFeedProvider);
    final myId = ref.watch(authControllerProvider).user?.id;
    final isoDay = Units.localDate(ref.watch(selectedDayProvider));
    final news = feed.moments
        .where((m) => _belongsTo(m, isoDay, myId))
        .toList(growable: false);

    // The feed pages newest-first, so a day further back than the oldest page
    // loaded has nothing to show yet — not because the day was quiet, but
    // because its moments have not been fetched. Keep pulling pages until the
    // feed reaches past that day or runs out.
    final reachedDay = feed.moments.isEmpty
        ? false
        : Units.localDate(
                DateTime.fromMillisecondsSinceEpoch(
                  feed.moments.last.createdAt,
                ),
              ).compareTo(isoDay) <=
              0;
    final digging = news.isEmpty && feed.hasMore && !reachedDay;
    if (digging && !feed.loadingMore) {
      // Mid-build, so the fetch waits for the frame to finish.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref.read(momentsFeedProvider.notifier).loadMore(),
      );
    }

    // Nothing for this day: the whole card goes, header and all. An error still
    // shows, otherwise a feed that keeps failing would look like a quiet day.
    if (!feed.loading && !digging && feed.error == null && news.isEmpty) {
      return const SizedBox.shrink();
    }

    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Cộng đồng',
                  style: TextStyle(fontSize: 12, color: RetroTokens.inkFaint),
                ),
              ),
              GestureDetector(
                onTap: () => context.go('/moments'),
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    children: [
                      Text(
                        'Xem tất cả',
                        style: TextStyle(
                          fontSize: 12,
                          color: RetroTokens.accent,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: RetroTokens.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CommunityBody(feed: feed, moments: news, digging: digging),
        ],
      ),
    );
  }
}

class _CommunityBody extends StatelessWidget {
  const _CommunityBody({
    required this.feed,
    required this.moments,
    this.digging = false,
  });

  final MomentsFeedState feed;

  /// True while older pages are still being pulled in for the day on screen:
  /// an empty list means "not fetched yet" rather than "nothing happened".
  final bool digging;

  /// Only what home counts as news; the state around it (loading, errors,
  /// the next page) still comes from [feed].
  final List<Moment> moments;

  @override
  Widget build(BuildContext context) {
    if (feed.loading || digging) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (moments.isEmpty) {
      return Text(
        feed.error != null
            ? '${feed.error}'
            : 'Chưa có khoảnh khắc nào. Chụp một tấm cho bạn bè.',
        style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
      );
    }

    return Column(
      children: [
        // Inside a ListView already, so this grid must not scroll on its own:
        // it lays out at its natural height and the page scrolls it.
        GridView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            // Square: with no caption or byline under it, the photo is the
            // whole tile.
            childAspectRatio: 1,
          ),
          itemCount: moments.length,
          itemBuilder: (_, i) => MomentTile(
            moment: moments[i],
            // Inside the community card: hairline border, no shadow, so the
            // tile reads as content of the card rather than a card in a card.
            nested: true,
            // Photo plus the author's face in the corner — the name and the
            // time belong to the full feed, not to this strip.
            compact: true,
            onTap: () => context.go('/moments'),
          ),
        ),
        if (feed.loadingMore)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(
        child: Text(
          'Chiphealth',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: RetroTokens.ink,
          ),
        ),
      ),
      IconButton(
        tooltip: 'Cài đặt',
        icon: const Icon(Icons.settings_outlined),
        onPressed: () => context.go('/profile'),
      ),
    ],
  );
}

/// T2..CN of the week containing the selected day. Future days are not
/// selectable — there is nothing logged in them yet.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.selected, required this.onSelect});

  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  static const _labels = ['T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'CN'];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Built by calendar arithmetic, not Duration, so a DST shift can never
    // hand back 23:00 the previous day and break the == below.
    final monday = DateTime(
      selected.year,
      selected.month,
      selected.day - (selected.weekday - 1),
    );

    // Expanded has to be a direct child of the Row, so the dates are computed
    // into a list first rather than inside a Builder.
    final days = [
      for (var i = 0; i < 7; i++)
        DateTime(monday.year, monday.month, monday.day + i),
    ];

    return Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: DayPip(
              label: _labels[i],
              day: days[i].day,
              selected: days[i] == selected,
              enabled: !days[i].isAfter(today),
              onTap: () => onSelect(days[i]),
            ),
          ),
        // The strip only reaches the current week; the calendar at its end is
        // the way to any other day without swiping a week at a time.
        _JumpToDay(selected: selected, today: today, onSelect: onSelect),
      ],
    );
  }
}

/// Calendar button at the end of the day strip: opens a month picker so a day
/// outside this week can be reached in one tap.
class _JumpToDay extends StatelessWidget {
  const _JumpToDay({
    required this.selected,
    required this.today,
    required this.onSelect,
  });

  final DateTime selected;
  final DateTime today;
  final ValueChanged<DateTime> onSelect;

  Future<void> _pick(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selected,
      // Nothing was logged before the app existed, and a day that has not
      // happened yet has nothing to show — two years back is more history
      // than any card on this screen reads.
      firstDate: DateTime(today.year - 2, today.month, today.day),
      lastDate: today,
      helpText: 'Chọn ngày',
      cancelText: 'Huỷ',
      confirmText: 'Xem',
    );
    if (picked == null) return;
    onSelect(DateTime(picked.year, picked.month, picked.day));
  }

  @override
  Widget build(BuildContext context) => Padding(
    // The pips carry a label above their ring; the icon sits on the ring row.
    padding: const EdgeInsets.only(left: 2, top: 17),
    child: SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        tooltip: 'Chọn ngày bất kỳ',
        iconSize: 20,
        color: RetroTokens.inkSoft,
        icon: const Icon(Icons.calendar_month_outlined),
        onPressed: () => _pick(context),
      ),
    ),
  );
}

class _OverviewSkeleton extends StatelessWidget {
  const _OverviewSkeleton();

  @override
  Widget build(BuildContext context) => const HomeCard(
    child: SizedBox(
      height: 180,
      child: Center(
        child: CircularProgressIndicator(color: RetroTokens.inkFaint),
      ),
    ),
  );
}

/// Mascot + the three energy lines, then a two-page macro carousel.
class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.daily,
    required this.controller,
    required this.page,
    required this.onPageChanged,
  });

  final DailyNutrition daily;
  final PageController controller;
  final int page;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    final targets = DailyTargets.fromDaily(daily);

    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Mascot(),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _EnergyLine(
                      icon: Icons.emoji_events_outlined,
                      label: 'Mục tiêu',
                      value: Units.kcal(targets.kcal),
                    ),
                    const SizedBox(height: 6),
                    _EnergyLine(
                      icon: Icons.restaurant,
                      label: 'Đã nạp',
                      value: Units.kcal(daily.consumedKcal),
                    ),
                    const SizedBox(height: 6),
                    _EnergyLine(
                      icon: Icons.local_fire_department_outlined,
                      label: 'Tiêu hao',
                      value: Units.kcal(daily.burnedKcal),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: RetroTokens.paperSunk, height: 1, thickness: 1),
          const SizedBox(height: 14),
          SizedBox(
            height: 66,
            child: PageView(
              controller: controller,
              onPageChanged: onPageChanged,
              children: [
                _MacroRow(
                  children: [
                    MacroBar(
                      label: 'Tinh bột',
                      value: daily.carbsG,
                      target: targets.carbsG,
                      unit: 'g',
                      color: RetroTokens.carbs,
                    ),
                    MacroBar(
                      label: 'Chất đạm',
                      value: daily.proteinG,
                      target: targets.proteinG,
                      unit: 'g',
                      color: RetroTokens.protein,
                    ),
                    MacroBar(
                      label: 'Chất béo',
                      value: daily.fatG,
                      target: targets.fatG,
                      unit: 'g',
                      color: RetroTokens.fat,
                    ),
                  ],
                ),
                _MacroRow(
                  children: [
                    MacroBar(
                      label: 'Đường',
                      value: daily.sugarG,
                      target: targets.sugarG,
                      unit: 'g',
                      color: RetroTokens.sugar,
                    ),
                    MacroBar(
                      label: 'Natri',
                      value: daily.sodiumMg,
                      target: targets.sodiumMg,
                      unit: 'mg',
                      color: RetroTokens.sodium,
                    ),
                    MacroBar(
                      label: 'Chất xơ',
                      value: daily.fiberG,
                      target: targets.fiberG,
                      unit: 'g',
                      color: RetroTokens.fiber,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          PageDots(count: 2, index: page),
        ],
      ),
    );
  }
}

class _MacroRow extends StatelessWidget {
  const _MacroRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(width: 14),
        Expanded(child: children[i]),
      ],
    ],
  );
}

class _EnergyLine extends StatelessWidget {
  const _EnergyLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  // Material icons rather than emoji: the web build ships no emoji font.
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 15, color: RetroTokens.inkSoft),
      const SizedBox(width: 6),
      Text(
        '$label:',
        style: const TextStyle(fontSize: 13, color: RetroTokens.inkSoft),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: RetroTokens.ink,
            ),
          ),
        ),
      ),
    ],
  );
}

/// Water is device-local (see WaterController) and always renders its cups on a
/// single row, however narrow the phone is.
class _WaterCard extends ConsumerWidget {
  const _WaterCard({required this.date});

  final String date;

  static final _ml = NumberFormat('#,##0');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drunk = ref.watch(waterProvider(date));
    final target = ref.watch(waterTargetProvider);
    final controller = ref.read(waterProvider(date).notifier);
    final cups = (target / WaterController.cupMl).ceil().clamp(4, 12).toInt();

    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Nước',
                      style: TextStyle(
                        fontSize: 12,
                        color: RetroTokens.inkFaint,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_ml.format(drunk)} ml',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
              ),
              AddButton(
                onTap: () => addWater(
                  context,
                  ref,
                  date: date,
                  drunk: drunk,
                  target: target,
                ),
                color: RetroTokens.water,
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Expanded cups can never wrap: the row divides whatever width it has
          // between the glasses, and FittedBox shrinks the icon to match.
          Row(
            children: [
              for (var i = 0; i < cups; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: _Cup(
                      // Filled to the millilitre, not by whole glasses: 380 ml
                      // is one full glass and a second one just over half.
                      fill: cupFillRatio(i, drunk),
                      onTap: () => i == 0 && drunk == 0
                          ? addWater(
                              context,
                              ref,
                              date: date,
                              drunk: drunk,
                              target: target,
                            )
                          : controller.setCups(i + 1),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Mục tiêu: ${_ml.format(target)} ml',
                  style: const TextStyle(
                    fontSize: 12,
                    color: RetroTokens.inkSoft,
                  ),
                ),
              ),
              PopupMenuButton<int>(
                tooltip: 'Tuỳ chọn nước',
                icon: const Icon(Icons.more_horiz, color: RetroTokens.inkSoft),
                onSelected: (value) {
                  if (value == 0) {
                    controller.reset();
                  } else {
                    ref.read(waterTargetProvider.notifier).set(value);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 1500, child: Text('Mục tiêu 1500 ml')),
                  PopupMenuItem(value: 2000, child: Text('Mục tiêu 2000 ml')),
                  PopupMenuItem(value: 2500, child: Text('Mục tiêu 2500 ml')),
                  PopupMenuItem(value: 3000, child: Text('Mục tiêu 3000 ml')),
                  PopupMenuItem(value: 0, child: Text('Đặt lại hôm nay')),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A glass filled from the bottom to [fill] (0..1).
class _Cup extends StatelessWidget {
  const _Cup({required this.fill, required this.onTap});

  final double fill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          const Icon(
            Icons.local_drink_outlined,
            size: 26,
            color: RetroTokens.inkFaint,
          ),
          // The water rises inside the outline: Align with a heightFactor
          // crops the filled glyph from the bottom up, so a half-drunk
          // glass reads as half full rather than as another empty one.
          if (fill > 0)
            ClipRect(
              clipper: _WaterLevel(fill),
              child: const Icon(
                Icons.local_drink,
                size: 26,
                color: RetroTokens.water,
              ),
            ),
        ],
      ),
    ),
  );
}

/// Keeps the bottom [fill] of the glyph and cuts the rest, so the water level
/// inside the glass is the millilitres actually logged.
class _WaterLevel extends CustomClipper<Rect> {
  const _WaterLevel(this.fill);

  final double fill;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(0, size.height * (1 - fill), size.width, size.height);

  @override
  bool shouldReclip(_WaterLevel oldClipper) => oldClipper.fill != fill;
}

/// Meals: calories eaten against the day's budget, a "+" that opens the food
/// screen, and the day's meals once there are any.
class _MealsCard extends StatelessWidget {
  const _MealsCard({required this.nutrition});

  final AsyncValue<DailyNutrition> nutrition;

  @override
  Widget build(BuildContext context) {
    final daily = nutrition.valueOrNull;
    // Eaten / budget, where the budget is the daily need plus whatever the
    // day's workouts burned. The API's TDEE already includes the workouts;
    // the fallback figure does not, so add them there.
    final consumed = (daily?.consumedKcal ?? 0).round();
    final budget =
        (daily?.tdeeKcal ??
                DailyTargets.fallbackKcal + (daily?.burnedKcal ?? 0))
            .round();
    final meals = [...?daily?.meals]
      ..sort((a, b) => b.loggedAt.compareTo(a.loggedAt));
    // Green while comfortably under budget, amber within ±100 kcal of it,
    // red once more than 100 over.
    final tone = consumed < budget - 100
        ? RetroTokens.ok
        : consumed <= budget + 100
        ? RetroTokens.warn
        : RetroTokens.accent;

    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHead(
            label: 'Các bữa ăn',
            value: '$consumed/$budget',
            valueColor: tone,
            unit: 'kcal',
            onAdd: () => context.go('/nutrition'),
          ),
          if (meals.isEmpty)
            const EmptyHint(text: 'Ghi lại bữa đầu tiên!')
          else ...[
            const SizedBox(height: 12),
            for (final meal in meals)
              // push, not go: the detail screen lives outside the shell, and
              // `go` would replace this route instead of stacking on it —
              // leaving its back button with nothing to pop.
              _MealRow(
                meal: meal,
                onTap: () => context.push('/meals/${meal.id}'),
              ),
          ],
        ],
      ),
    );
  }
}

class _MealRow extends StatelessWidget {
  const _MealRow({required this.meal, required this.onTap});

  final MealLog meal;
  final VoidCallback onTap;

  static const _types = {
    'breakfast': 'Bữa sáng',
    'lunch': 'Bữa trưa',
    'dinner': 'Bữa tối',
    'snack': 'Bữa phụ',
  };

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              meal.dishName ?? _types[meal.mealType] ?? meal.mealType,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            Units.kcal(meal.totalCaloriesKcal),
            style: const TextStyle(fontSize: 13, color: RetroTokens.inkSoft),
          ),
        ],
      ),
    ),
  );
}

/// Activity mirrors the meals card: burned calories and a "+" that starts a
/// recording.
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.nutrition});

  final AsyncValue<DailyNutrition> nutrition;

  @override
  Widget build(BuildContext context) {
    final burned = nutrition.valueOrNull?.burnedKcal ?? 0;

    // The card body opens the activity feed; only "+" jumps straight into a
    // new recording.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.go('/training'),
      child: HomeCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CardHead(
              label: 'Hoạt động',
              value: '${burned.round()}',
              unit: 'kcal',
              // Full-screen route, not a tab: push so the recorder can be backed
              // out of.
              onAdd: () => context.push('/record'),
            ),
            if (burned <= 0)
              const EmptyHint(text: 'Ghi lại hoạt động đầu tiên!')
            else ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => context.go('/training'),
                child: const Text('Xem buổi tập hôm nay'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CardHead extends StatelessWidget {
  const _CardHead({
    required this.label,
    required this.value,
    required this.unit,
    required this.onAdd,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final String unit;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: RetroTokens.inkFaint),
            ),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      maxLines: 1,
                      softWrap: false,
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge?.copyWith(color: valueColor),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: const TextStyle(
                    fontSize: 12,
                    color: RetroTokens.inkSoft,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      AddButton(onTap: onAdd, size: 48),
    ],
  );
}
