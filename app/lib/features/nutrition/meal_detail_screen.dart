import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format/units.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/repositories/repositories.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import '../../widgets/unsaved_changes_bar.dart';
import 'meal_health_score.dart';
import 'meal_photo.dart';
import 'moment_compose_dialog.dart';

/// The correction surface, and the last step of logging a meal.
///
/// Until the analysis lands the meal is a draft: if it fails there is nothing
/// worth keeping, so the user is offered a retry, and walking away throws the
/// row out rather than leaving a 0 kcal ghost in the day. A run that is still
/// going after 3 minutes counts as failed — the server reports it as such, and
/// the local clock ends the wait if that verdict never arrives.
class MealDetailScreen extends ConsumerStatefulWidget {
  const MealDetailScreen({super.key, required this.mealId});

  final String mealId;

  @override
  ConsumerState<MealDetailScreen> createState() => _MealDetailScreenState();
}

class _MealDetailScreenState extends ConsumerState<MealDetailScreen> {
  MealLog? _meal;
  Object? _error;
  Timer? _poll;
  bool _discarded = false;
  bool _kept = false;

  /// The local half of the 3-minute analysis timeout: set when the deadline
  /// passed but the server still says `running`, so the wait ends here rather
  /// than depending on the next poll delivering the verdict.
  bool _localTimeout = false;

  /// Components the user has taken off with "−" but has not saved yet. Ids, not
  /// items, so a reload between the tap and "Lưu" does not resurrect them.
  final Set<int> _removed = <int>{};
  bool _saving = false;

  /// Held rather than read on demand: the discard-on-leave path runs from
  /// dispose(), where reading a provider is no longer allowed.
  late final NutritionRepository _repo = ref.read(nutritionRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    // Leaving a failed draft that cannot be re-run (a spoken meal, whose clip
    // is gone) discards it. A photo meal is kept: it stays in the list so the
    // user can come back and retry. Fire-and-forget: the screen is already gone.
    final meal = _meal;
    if (!_kept &&
        !_discarded &&
        meal != null &&
        meal.isFailedDraft &&
        meal.photoAssetId == null) {
      unawaited(_repo.deleteMeal(widget.mealId).catchError((_) {}));
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final meal = await _repo.meal(widget.mealId);
      if (!mounted) return;
      setState(() {
        _meal = meal;
        _error = null;
      });
      // Analysis runs in the background on the server; poll until it lands.
      // The server reports a run past the 3-minute deadline as failed inside
      // this very poll; the local clock below is only the backstop for a
      // verdict that arrives late or never — the wait is bounded either way.
      if (meal.isAnalysing) {
        if (meal.timedOutAt(DateTime.now().millisecondsSinceEpoch)) {
          _poll?.cancel();
          setState(() => _localTimeout = true);
          return;
        }
        _poll?.cancel();
        _poll = Timer(const Duration(seconds: 2), _load);
      }
    } catch (err) {
      if (mounted) setState(() => _error = err);
    }
  }

  Future<void> _retry() async {
    final meal = _meal;
    if (meal == null) return;
    // Re-running needs the photo: a spoken meal's clip is transcribed and thrown
    // away, so there is nothing left to analyse a second time.
    if (meal.photoAssetId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bữa ăn nói không phân tích lại được — hãy nhập lại.'),
        ),
      );
      return;
    }
    setState(() {
      _meal = null;
      _localTimeout = false;
    });
    try {
      await _repo.analyze(widget.mealId);
      await _load();
    } catch (err) {
      if (mounted) setState(() => _error = err);
    }
  }

  Future<void> _discard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hủy bỏ bữa ăn?'),
        content: const Text('Bữa ăn này và mọi thành phần của nó sẽ bị xóa.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Giữ lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hủy bỏ'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    _discarded = true;
    try {
      await _repo.deleteMeal(widget.mealId);
      ref.invalidate(dailyNutritionProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      _discarded = false;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    }
  }

  Future<void> _editItem(MealItem item) async {
    final edited = await showModalBottomSheet<MealItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RetroTokens.panelRaised,
      builder: (_) => _ItemEditor(item: item),
    );
    if (edited == null) return;

    try {
      await _repo.correctItem(widget.mealId, item.id, edited);
      ref.invalidate(dailyNutritionProvider);
      await _load();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    }
  }

  /// "−" takes the component off the screen; nothing is sent until "Lưu". The
  /// user asked for a correction surface, and a correction you cannot back out
  /// of before saving is not a correction.
  void _removeItem(MealItem item) {
    setState(() => _removed.add(item.id));
  }

  Future<void> _addItem() async {
    final added = await showModalBottomSheet<MealItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RetroTokens.panelRaised,
      builder: (_) => const _ItemEditor(item: null),
    );
    if (added == null) return;
    try {
      await _repo.addItem(widget.mealId, added);
      ref.invalidate(dailyNutritionProvider);
      await _load();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    }
  }

  /// "Chỉnh sửa" opens the whole meal, not just its components: what the dish
  /// is called, which meal it counts as, when it was eaten, and every component
  /// under it. The vision model guessed all of that, so all of it is correctable.
  Future<void> _editMeal() async {
    final meal = _meal;
    if (meal == null) return;
    final items = meal.items.where((i) => !_removed.contains(i.id)).toList();

    final result = await showModalBottomSheet<_MealEdit>(
      context: context,
      isScrollControlled: true,
      backgroundColor: RetroTokens.panelRaised,
      builder: (_) => _MealEditor(meal: meal, items: items),
    );
    if (result == null || !mounted) return;

    switch (result) {
      case _EditComponent(:final item):
        await _editItem(item);
      case _AddComponent():
        await _addItem();
      case _MealFields(
        :final dishName,
        :final mealType,
        :final loggedAt,
        :final note,
      ):
        await _saveMealFields(
          dishName: dishName,
          mealType: mealType,
          loggedAt: loggedAt,
          note: note,
        );
    }
  }

  /// The meal's own fields. Unlike a staged removal these write straight away —
  /// there is nothing to undo about a name that is now correct.
  Future<void> _saveMealFields({
    required String dishName,
    required String mealType,
    required int loggedAt,
    required String note,
  }) async {
    try {
      await _repo.updateMeal(
        widget.mealId,
        dishName: dishName,
        mealType: mealType,
        loggedAt: loggedAt,
        note: note,
      );
      ref.invalidate(dailyNutritionProvider);
      await _load();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    }
  }

  /// The share sheet. "Chia sẻ" means two different places at once — the app's
  /// own feed, where friends already follow this user's meals, and everywhere
  /// else through the platform sheet (Facebook, Instagram, Zalo…) — so both are
  /// offered, with a plain copy for whatever neither reaches.
  Future<void> _share() async {
    final meal = _meal;
    if (meal == null) return;

    final target = await showModalBottomSheet<_ShareTarget>(
      context: context,
      backgroundColor: RetroTokens.panelRaised,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Chia sẻ bữa ăn',
                  style: TextStyle(
                    color: RetroTokens.onPanel,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            // Moments are photo posts: a meal logged by voice has no picture to
            // put in the feed, so that destination is simply not offered.
            if (meal.photoAssetId != null)
              ListTile(
                leading: const Icon(
                  Icons.auto_awesome_motion,
                  color: RetroTokens.onPanel,
                ),
                title: const Text(
                  'Đăng lên Khoảnh khắc',
                  style: TextStyle(color: RetroTokens.onPanel),
                ),
                subtitle: const Text(
                  'Bạn bè trong ChipHealth nhìn thấy',
                  style: TextStyle(color: RetroTokens.onPanelSoft),
                ),
                onTap: () => Navigator.pop(ctx, _ShareTarget.moment),
              ),
            ListTile(
              leading: const Icon(Icons.share, color: RetroTokens.onPanel),
              title: const Text(
                'Chia sẻ lên mạng xã hội',
                style: TextStyle(color: RetroTokens.onPanel),
              ),
              subtitle: const Text(
                'Facebook, Instagram, Zalo, Messenger…',
                style: TextStyle(color: RetroTokens.onPanelSoft),
              ),
              onTap: () => Navigator.pop(ctx, _ShareTarget.external),
            ),
            ListTile(
              leading: const Icon(Icons.copy, color: RetroTokens.onPanel),
              title: const Text(
                'Sao chép nội dung',
                style: TextStyle(color: RetroTokens.onPanel),
              ),
              onTap: () => Navigator.pop(ctx, _ShareTarget.clipboard),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;

    switch (target) {
      case _ShareTarget.moment:
        await _postMoment(meal);
      case _ShareTarget.external:
        await SharePlus.instance.share(ShareParams(text: _shareText(meal)));
      case _ShareTarget.clipboard:
        await Clipboard.setData(ClipboardData(text: _shareText(meal)));
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(const SnackBar(content: Text('Đã sao chép')));
        }
    }
  }

  /// What goes out with the meal: the dish, what it cost, and what it was made
  /// of — the same three things the screen leads with.
  String _shareText(MealLog meal) {
    final name = meal.dishName?.isNotEmpty == true
        ? meal.dishName!
        : _mealLabel(meal.mealType);
    return '$name · ${Units.kcal(meal.totalCaloriesKcal)}\n'
        'Đạm ${Units.grams(meal.totalProteinG)} · '
        'Tinh bột ${Units.grams(meal.totalCarbsG)} · '
        'Béo ${Units.grams(meal.totalFatG)}\n'
        'Ghi bằng ChipHealth';
  }

  /// The meal's own photo becomes the moment, linked back to the meal so the
  /// feed can open it. The user reviews the photo and writes the caption first.
  Future<void> _postMoment(MealLog meal) async {
    final photo = meal.photoAssetId;
    if (photo == null) return;
    final caption = await showMomentComposeDialog(
      context,
      photoAssetId: photo,
      initialCaption: _shareText(meal),
    );
    if (caption == null || !mounted) return;
    try {
      await ref
          .read(momentsRepositoryProvider)
          .post(
            photoAssetId: photo,
            caption: caption.isEmpty ? null : caption,
            linkedMealLogId: meal.id,
          );
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(content: Text('Đã đăng lên Khoảnh khắc')),
          );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    }
  }

  /// Saving is where staged removals actually happen. Everything else on this
  /// screen writes as it is edited; only "−" waits for this. The user stays on
  /// the meal afterwards, like the settings page: the bar just goes away.
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      for (final id in _removed.toList()) {
        await _repo.deleteItem(widget.mealId, id);
        _removed.remove(id);
      }
      _kept = true;
      ref.invalidate(dailyNutritionProvider);
      await _load();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$err')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final meal = _meal;

    return Scaffold(
      backgroundColor: RetroTokens.paper,
      body: SafeArea(
        child: PhoneFrame(
          child: _error != null
              // The header stays: an error the user cannot back out of is a
              // trap, and the meal may still be worth throwing away.
              ? Column(
                  children: [
                    _Header(onDiscard: _discard),
                    Expanded(
                      child: _CenteredMessage(
                        text: '$_error',
                        actionLabel: 'Thử lại',
                        onAction: () {
                          setState(() => _error = null);
                          _load();
                        },
                      ),
                    ),
                  ],
                )
              : meal == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    _body(meal),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: UnsavedChangesBar(
                        visible: _removed.isNotEmpty || _saving,
                        saving: _saving,
                        onReset: () => setState(_removed.clear),
                        onSave: _save,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _body(MealLog meal) {
    // Still `running` past the deadline with no server verdict yet: the wait
    // is over locally, and the same retry offer is shown as for a failure.
    final stuck = meal.isAnalysing && _localTimeout;

    if (meal.isAnalysing && !stuck) {
      return Column(
        children: [
          _Header(onDiscard: _discard),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The photo is what is being analysed, so while the model runs
                  // it is the whole screen rather than a thumbnail in a corner.
                  MealPhotoThumb(assetId: meal.photoAssetId, size: 240),
                  const SizedBox(height: 28),
                  const CircularProgressIndicator(),
                  const SizedBox(height: 14),
                  const Text(
                    'Đang phân tích…',
                    style: TextStyle(color: RetroTokens.inkSoft),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // A timeout is worth its own words: it says the model hung, not that the
    // photo was unreadable, so retrying is expected to work.
    if (meal.isFailedDraft || stuck) {
      final timedOut = stuck || meal.analysisTimedOut;
      // Nothing was ever recorded: the call that starts the analysis never
      // landed, which is a connection problem and says so.
      final never = meal.analysisNeverRan;
      // A spoken meal's clip is transcribed and thrown away, so there is
      // nothing left to run a second time: that draft can only be discarded.
      final canRetry = meal.photoAssetId != null;
      return Column(
        children: [
          _Header(onDiscard: _discard),
          Expanded(
            child: _CenteredMessage(
              text: !canRetry
                  ? 'Bữa ăn này chưa được phân tích và không chạy lại được — hãy ghi lại.'
                  : timedOut
                  ? 'Phân tích kéo dài quá 3 phút. Hãy thử lại nhé.'
                  : never
                  ? 'Chưa phân tích được bữa ăn này — không kết nối được máy chủ.'
                  : 'Không phân tích được bữa ăn này.',
              actionLabel: canRetry ? 'Thử lại' : 'Hủy bỏ',
              onAction: canRetry ? _retry : _discard,
              secondaryLabel: canRetry ? 'Hủy bỏ' : null,
              onSecondary: canRetry ? _discard : null,
            ),
          ),
        ],
      );
    }

    // Everything below the header reads off the staged meal, so a component the
    // user has taken off is gone from the totals, the score and the fibre bar
    // before it is gone from the server.
    final view = meal.withItems(
      meal.items.where((i) => !_removed.contains(i.id)).toList(),
    );
    final score = MealHealthScore.of(view);

    return ListView(
      // Room for the save bar, so it never hides the last card.
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        _Header(onDiscard: _discard, onShare: _share),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Units.timeOfDay(meal.loggedAt),
                      style: const TextStyle(
                        color: RetroTokens.inkFaint,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      meal.dishName?.isNotEmpty == true
                          ? meal.dishName!
                          : _mealLabel(meal.mealType),
                      style: const TextStyle(
                        fontSize: 28,
                        height: 1.15,
                        fontWeight: FontWeight.w800,
                        color: RetroTokens.ink,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Icon(
                          Icons.favorite,
                          size: 18,
                          color: RetroTokens.fat,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Sức Khỏe: ${score.value}/10',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: RetroTokens.inkSoft,
                          ),
                        ),
                        if (score.reasons.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '· ${score.reasons.first}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: RetroTokens.inkFaint,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              // Next to the name it belongs to, not floating off the header.
              MealPhotoThumb(assetId: meal.photoAssetId, size: 88),
            ],
          ),
        ),
        _NutritionCard(meal: view, onEdit: _editMeal),
        const SizedBox(height: 14),
        _IngredientsCard(
          meal: view,
          onRemove: _removeItem,
          onTap: _editItem,
          onAdd: _addItem,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Where a shared meal can go.
enum _ShareTarget { moment, external, clipboard }

String _mealLabel(String type) => switch (type) {
  'breakfast' => 'Bữa sáng',
  'lunch' => 'Bữa trưa',
  'dinner' => 'Bữa tối',
  _ => 'Bữa phụ',
};

/// Back arrow on the left; share and the "hủy bỏ" menu in the top-right corner.
class _Header extends StatelessWidget {
  const _Header({required this.onDiscard, this.onShare});

  final VoidCallback onDiscard;

  /// Null while the meal is still a draft: there is nothing to show off yet.
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: RetroTokens.ink),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onShare != null)
                IconButton(
                  icon: const Icon(Icons.ios_share, color: RetroTokens.ink),
                  tooltip: 'Chia sẻ',
                  onPressed: onShare,
                ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: RetroTokens.ink),
                onSelected: (v) {
                  if (v == 'discard') onDiscard();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'discard',
                    child: Text(
                      'Hủy bỏ bữa ăn',
                      style: TextStyle(color: RetroTokens.accent),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Weight, energy, the macro split as one bar, and the three numbers under it.
class _NutritionCard extends StatelessWidget {
  const _NutritionCard({required this.meal, required this.onEdit});

  final MealLog meal;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final grams = meal.items.fold<double>(0, (s, i) => s + i.quantityG);
    final sugar = meal.items.fold<double>(0, (s, i) => s + (i.sugarG ?? 0));
    final sodium = meal.items.fold<double>(0, (s, i) => s + (i.sodiumMg ?? 0));
    final fiber = meal.items.fold<double>(0, (s, i) => s + (i.fiberG ?? 0));
    // Null when nothing in the meal was ever given a water estimate — an
    // un-analysed meal has not said "0 ml", it has said nothing.
    final water = meal.items.any((i) => i.waterMl != null)
        ? meal.items.fold<double>(0, (s, i) => s + (i.waterMl ?? 0))
        : null;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Calo & Dinh dưỡng',
                  style: TextStyle(
                    color: RetroTokens.onPanelSoft,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _Pill(label: 'Chỉnh sửa', onTap: onEdit),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _BigNumber(value: grams.round().toString(), unit: 'g'),
              const Spacer(),
              _BigNumber(
                value: meal.totalCaloriesKcal.round().toString(),
                unit: 'kcal',
              ),
            ],
          ),
          const SizedBox(height: 16),
          _MacroBar(
            carbs: meal.totalCarbsG,
            protein: meal.totalProteinG,
            fat: meal.totalFatG,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _MacroColumn(
                  color: RetroTokens.carbs,
                  icon: Icons.bakery_dining,
                  label: 'Tinh bột',
                  grams: meal.totalCarbsG,
                ),
              ),
              Expanded(
                child: _MacroColumn(
                  color: RetroTokens.protein,
                  icon: Icons.egg_alt,
                  label: 'Chất đạm',
                  grams: meal.totalProteinG,
                ),
              ),
              Expanded(
                child: _MacroColumn(
                  color: RetroTokens.fat,
                  icon: Icons.water_drop,
                  label: 'Chất béo',
                  grams: meal.totalFatG,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: RetroTokens.panelLine, height: 1),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _MacroColumn(
                  color: RetroTokens.sugar,
                  icon: Icons.grain,
                  label: 'Đường',
                  grams: sugar,
                ),
              ),
              Expanded(
                child: _MacroColumn(
                  color: RetroTokens.sodium,
                  icon: Icons.blur_on,
                  label: 'Natri',
                  grams: sodium,
                  unit: 'mg',
                ),
              ),
              Expanded(
                child: _MacroColumn(
                  color: RetroTokens.fiber,
                  icon: Icons.grass,
                  label: 'Chất xơ',
                  grams: fiber,
                ),
              ),
            ],
          ),
          if (water != null) ...[
            const SizedBox(height: 14),
            const Divider(color: RetroTokens.panelLine, height: 1),
            const SizedBox(height: 12),
            _WaterLine(millilitres: water),
          ],
          if (meal.analysisStatus != null) ...[
            const SizedBox(height: 14),
            const Divider(color: RetroTokens.panelLine, height: 1),
            const SizedBox(height: 10),
            _AnalysisVote(mealId: meal.id, vote: meal.analysisFeedback),
          ],
        ],
      ),
    );
  }
}

/// What the meal contributed to the day's fluid: the drinks in full, plus the
/// broth and the water inside the food. It gets its own line rather than a
/// column next to the macros — it is the one figure here measured in ml, and
/// it is an estimate of a different thing than the nutrients above it.
class _WaterLine extends StatelessWidget {
  const _WaterLine({required this.millilitres});

  final double millilitres;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.water_drop, size: 15, color: RetroTokens.water),
      const SizedBox(width: 6),
      const Expanded(
        child: Text(
          'Nước',
          style: TextStyle(color: RetroTokens.onPanelSoft, fontSize: 12),
        ),
      ),
      Text(
        millilitres.round().toString(),
        style: const TextStyle(
          color: RetroTokens.onPanel,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(width: 2),
      const Text(
        'ml',
        style: TextStyle(color: RetroTokens.onPanelSoft, fontSize: 12),
      ),
    ],
  );
}

/// Thumbs on the analysis, kept server-side on the analysis row it judges.
///
/// Only shown for a meal that was actually analysed: a hand-typed meal has no
/// attempt to vote on, and asking about one would be asking about nothing.
class _AnalysisVote extends ConsumerStatefulWidget {
  const _AnalysisVote({required this.mealId, required this.vote});

  final String mealId;

  /// 'up', 'down', or null — as the server last recorded it.
  final String? vote;

  @override
  ConsumerState<_AnalysisVote> createState() => _AnalysisVoteState();
}

class _AnalysisVoteState extends ConsumerState<_AnalysisVote> {
  late String? _vote = widget.vote;

  @override
  void didUpdateWidget(_AnalysisVote old) {
    super.didUpdateWidget(old);
    // A reload brings the stored verdict back; adopt it unless the tap that is
    // in flight already moved past it.
    if (old.vote != widget.vote) _vote = widget.vote;
  }

  /// Optimistic: the thumb lights on the tap and falls back if the write fails,
  /// because a vote is not worth a spinner.
  Future<void> _cast(String value) async {
    final previous = _vote;
    final next = _vote == value ? null : value;
    setState(() => _vote = next);
    try {
      await ref
          .read(nutritionRepositoryProvider)
          .voteAnalysis(widget.mealId, next);
    } catch (err) {
      if (!mounted) return;
      setState(() => _vote = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$err')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'ChipHealth phân tích thế nào?',
            style: TextStyle(color: RetroTokens.onPanelSoft, fontSize: 13),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(
            _vote == 'up' ? Icons.thumb_up_alt : Icons.thumb_up_alt_outlined,
            size: 18,
            color: _vote == 'up' ? RetroTokens.fat : RetroTokens.onPanelSoft,
          ),
          onPressed: () => _cast('up'),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Icon(
            _vote == 'down'
                ? Icons.thumb_down_alt
                : Icons.thumb_down_alt_outlined,
            size: 18,
            color: _vote == 'down'
                ? RetroTokens.accent
                : RetroTokens.onPanelSoft,
          ),
          onPressed: () => _cast('down'),
        ),
      ],
    );
  }
}

class _IngredientsCard extends StatelessWidget {
  const _IngredientsCard({
    required this.meal,
    required this.onRemove,
    required this.onTap,
    required this.onAdd,
  });

  final MealLog meal;
  final void Function(MealItem) onRemove;
  final void Function(MealItem) onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Thành phần',
            style: TextStyle(
              color: RetroTokens.onPanelSoft,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          if (meal.items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text(
                'Chưa có thành phần nào.',
                style: TextStyle(color: RetroTokens.onPanelSoft),
              ),
            ),
          for (var i = 0; i < meal.items.length; i++) ...[
            if (i > 0) const Divider(color: RetroTokens.panelLine, height: 1),
            _IngredientRow(
              item: meal.items[i],
              onRemove: () => onRemove(meal.items[i]),
              onTap: () => onTap(meal.items[i]),
            ),
          ],
          const SizedBox(height: 6),
          Center(
            child: TextButton(
              onPressed: onAdd,
              child: const Text(
                '+ Thêm thành phần mới',
                style: TextStyle(color: RetroTokens.onPanel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({
    required this.item,
    required this.onRemove,
    required this.onTap,
  });

  final MealItem item;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.ingredientName,
                    style: const TextStyle(
                      color: RetroTokens.onPanel,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Text(
                        '${item.quantityG.round()} g · '
                        '${Units.kcal(item.caloriesKcal)}'
                        // Only where it is worth saying: a drink or a broth,
                        // not the two millilitres inside a slice of pork.
                        '${(item.waterMl ?? 0) >= 20 ? ' · ${item.waterMl!.round()} ml' : ''}',
                        style: const TextStyle(
                          color: RetroTokens.onPanelSoft,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 10),
                      _Dot(color: RetroTokens.carbs, value: item.carbsG),
                      _Dot(color: RetroTokens.protein, value: item.proteinG),
                      _Dot(color: RetroTokens.fat, value: item.fatG),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onRemove,
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                backgroundColor: RetroTokens.panelFill,
                shape: const CircleBorder(),
              ),
              icon: const Icon(
                Icons.remove,
                size: 16,
                color: RetroTokens.onPanel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.value});

  final Color color;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 6,
            width: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            value == null ? '–' : value!.round().toString(),
            style: const TextStyle(
              color: RetroTokens.onPanelSoft,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------------------------------------ small pieces */

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: RetroTokens.panel,
        border: Border.all(color: RetroTokens.panelLine),
        borderRadius: BorderRadius.circular(28),
      ),
      child: child,
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: RetroTokens.panelFill,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: RetroTokens.onPanel,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class _BigNumber extends StatelessWidget {
  const _BigNumber({required this.value, required this.unit});

  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(
        value,
        style: const TextStyle(
          color: RetroTokens.onPanel,
          fontSize: 34,
          height: 1,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(width: 5),
      Text(
        unit,
        style: const TextStyle(color: RetroTokens.onPanelSoft, fontSize: 14),
      ),
    ],
  );
}

/// One bar, three segments, in the order the columns under it are read.
class _MacroBar extends StatelessWidget {
  const _MacroBar({
    required this.carbs,
    required this.protein,
    required this.fat,
  });

  final double carbs;
  final double protein;
  final double fat;

  @override
  Widget build(BuildContext context) {
    final total = carbs + protein + fat;
    if (total <= 0) {
      return Container(
        height: 10,
        decoration: BoxDecoration(
          color: RetroTokens.panelFill,
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 10,
        child: Row(
          children: [
            Expanded(
              flex: (carbs * 100).round().clamp(1, 1000000),
              child: Container(color: RetroTokens.carbs),
            ),
            Expanded(
              flex: (protein * 100).round().clamp(1, 1000000),
              child: Container(color: RetroTokens.protein),
            ),
            Expanded(
              flex: (fat * 100).round().clamp(1, 1000000),
              child: Container(color: RetroTokens.fat),
            ),
          ],
        ),
      ),
    );
  }
}

class _MacroColumn extends StatelessWidget {
  const _MacroColumn({
    required this.color,
    required this.icon,
    required this.label,
    required this.grams,
    this.unit = 'g',
  });

  final Color color;
  final IconData icon;
  final String label;
  final double grams;
  final String unit;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: RetroTokens.onPanelSoft,
              fontSize: 12,
            ),
          ),
        ],
      ),
      const SizedBox(height: 5),
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            grams.round().toString(),
            style: const TextStyle(
              color: RetroTokens.onPanel,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            unit,
            style: const TextStyle(
              color: RetroTokens.onPanelSoft,
              fontSize: 12,
            ),
          ),
        ],
      ),
    ],
  );
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.text,
    required this.actionLabel,
    required this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String text;
  final String actionLabel;
  final VoidCallback onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: RetroTokens.inkSoft),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: onAction, child: Text(actionLabel)),
          if (secondaryLabel != null)
            TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
        ],
      ),
    ),
  );
}

/// What the meal editor came back with: either the meal's own fields, or a
/// request to go on and edit one component.
sealed class _MealEdit {
  const _MealEdit();
}

class _MealFields extends _MealEdit {
  const _MealFields({
    required this.dishName,
    required this.mealType,
    required this.loggedAt,
    required this.note,
  });

  final String dishName;
  final String mealType;
  final int loggedAt;
  final String note;
}

class _EditComponent extends _MealEdit {
  const _EditComponent(this.item);
  final MealItem item;
}

class _AddComponent extends _MealEdit {
  const _AddComponent();
}

/// The whole meal in one sheet: name, which meal it counts as, when it was
/// eaten, a note, and the components under it. The components keep their own
/// editor — this one hands the tap back so the screen can open it.
class _MealEditor extends StatefulWidget {
  const _MealEditor({required this.meal, required this.items});

  final MealLog meal;

  /// Components as they stand on screen — staged removals already taken off.
  final List<MealItem> items;

  @override
  State<_MealEditor> createState() => _MealEditorState();
}

class _MealEditorState extends State<_MealEditor> {
  late final _name = TextEditingController(text: widget.meal.dishName ?? '');
  late final _note = TextEditingController(text: widget.meal.note ?? '');
  late String _type = widget.meal.mealType;
  late DateTime _at = DateTime.fromMillisecondsSinceEpoch(widget.meal.loggedAt);

  static const _types = ['breakfast', 'lunch', 'dinner', 'snack'];

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _at,
      // A meal is logged after it is eaten, so the future is not a date it can
      // land on; a year back is more history than the diary needs.
      firstDate: DateTime(now.year - 1),
      lastDate: now,
    );
    if (picked == null) return;
    setState(
      () => _at = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _at.hour,
        _at.minute,
      ),
    );
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    if (picked == null) return;
    setState(
      () => _at = DateTime(
        _at.year,
        _at.month,
        _at.day,
        picked.hour,
        picked.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Chỉnh sửa bữa ăn',
              style: TextStyle(
                color: RetroTokens.onPanel,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              style: const TextStyle(color: RetroTokens.onPanel),
              decoration: const InputDecoration(
                labelText: 'Tên món',
                labelStyle: TextStyle(color: RetroTokens.onPanelSoft),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                for (final t in _types)
                  ChoiceChip(
                    label: Text(_mealLabel(t)),
                    selected: _type == t,
                    onSelected: (_) => setState(() => _type = t),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(
                      Units.dayHeading(
                        '${_at.year.toString().padLeft(4, '0')}-'
                        '${_at.month.toString().padLeft(2, '0')}-'
                        '${_at.day.toString().padLeft(2, '0')}',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(Units.timeOfDay(_at.millisecondsSinceEpoch)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _note,
              style: const TextStyle(color: RetroTokens.onPanel),
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Ghi chú',
                labelStyle: TextStyle(color: RetroTokens.onPanelSoft),
              ),
            ),
            const SizedBox(height: 14),
            const Divider(color: RetroTokens.panelLine, height: 1),
            const Padding(
              padding: EdgeInsets.only(top: 10, bottom: 2),
              child: Text(
                'Thành phần',
                style: TextStyle(
                  color: RetroTokens.onPanelSoft,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final item in widget.items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  item.ingredientName,
                  style: const TextStyle(color: RetroTokens.onPanel),
                ),
                subtitle: Text(
                  '${item.quantityG.round()} g · ${Units.kcal(item.caloriesKcal)}',
                  style: const TextStyle(color: RetroTokens.onPanelSoft),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: RetroTokens.onPanelSoft,
                ),
                onTap: () => Navigator.pop(context, _EditComponent(item)),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Navigator.pop(context, const _AddComponent()),
                child: const Text(
                  '+ Thêm thành phần mới',
                  style: TextStyle(color: RetroTokens.onPanel),
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                _MealFields(
                  dishName: _name.text.trim(),
                  mealType: _type,
                  loggedAt: _at.millisecondsSinceEpoch,
                  note: _note.text.trim(),
                ),
              ),
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }
}

/// One component, editable. `item == null` adds a new one instead of correcting
/// an existing one — the fields are the same either way.
class _ItemEditor extends StatefulWidget {
  const _ItemEditor({required this.item});

  final MealItem? item;

  @override
  State<_ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<_ItemEditor> {
  late final _name = TextEditingController(text: widget.item?.ingredientName);
  late final _grams = TextEditingController(text: _num(widget.item?.quantityG));
  late final _kcal = TextEditingController(
    text: _num(widget.item?.caloriesKcal),
  );
  late final _protein = TextEditingController(
    text: _num(widget.item?.proteinG),
  );
  late final _carbs = TextEditingController(text: _num(widget.item?.carbsG));
  late final _fat = TextEditingController(text: _num(widget.item?.fatG));
  late final _fiber = TextEditingController(text: _num(widget.item?.fiberG));
  late final _sugar = TextEditingController(text: _num(widget.item?.sugarG));
  late final _sodium = TextEditingController(text: _num(widget.item?.sodiumMg));
  late final _water = TextEditingController(text: _num(widget.item?.waterMl));

  static String _num(double? v) => v == null ? '' : v.toStringAsFixed(0);
  static double? _parse(String s) =>
      s.trim().isEmpty ? null : double.tryParse(s.trim());

  @override
  Widget build(BuildContext context) {
    final adding = widget.item == null;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              adding ? 'Thêm thành phần' : 'Sửa thành phần',
              style: const TextStyle(
                color: RetroTokens.onPanel,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 12),
            _field(_name, 'Tên', text: true),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _field(_grams, 'Khối lượng (g)')),
                const SizedBox(width: 8),
                Expanded(child: _field(_kcal, 'Calo (kcal)')),
                const SizedBox(width: 8),
                Expanded(child: _field(_water, 'Nước (ml)')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _field(_carbs, 'Tinh bột (g)')),
                const SizedBox(width: 8),
                Expanded(child: _field(_protein, 'Đạm (g)')),
                const SizedBox(width: 8),
                Expanded(child: _field(_fat, 'Béo (g)')),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _field(_fiber, 'Xơ (g)')),
                const SizedBox(width: 8),
                Expanded(child: _field(_sugar, 'Đường (g)')),
                const SizedBox(width: 8),
                Expanded(child: _field(_sodium, 'Natri (mg)')),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                final name = _name.text.trim();
                if (name.isEmpty) return;
                Navigator.of(context).pop(
                  MealItem(
                    id: widget.item?.id ?? 0,
                    ingredientName: name,
                    quantityG: _parse(_grams.text) ?? 0,
                    caloriesKcal: _parse(_kcal.text) ?? 0,
                    proteinG: _parse(_protein.text),
                    carbsG: _parse(_carbs.text),
                    fatG: _parse(_fat.text),
                    fiberG: _parse(_fiber.text),
                    sugarG: _parse(_sugar.text),
                    sodiumMg: _parse(_sodium.text),
                    waterMl: _parse(_water.text),
                    isUserCorrected: true,
                  ),
                );
              },
              child: Text(adding ? 'Thêm' : 'Lưu'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {bool text = false}) =>
      TextField(
        controller: c,
        style: const TextStyle(color: RetroTokens.onPanel),
        keyboardType: text
            ? TextInputType.text
            : const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: RetroTokens.onPanelSoft),
        ),
      );
}
