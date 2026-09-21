import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import '../../widgets/unsaved_changes_bar.dart';
import '../../core/l10n/gen/app_localizations.dart';

final meProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(profileRepositoryProvider).me(),
);

/// `/v1/me/tdee`: the personal details form reads its starting values from
/// here, since it already joins the profile with the latest weight and height.
final tdeeInfoProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(profileRepositoryProvider).tdee(),
);

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final tdee = ref.watch(tdeeInfoProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppL10n.of(context).caNhan),
        actions: [
          TextButton(
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
            child: Text(AppL10n.of(context).dangXuat),
          ),
        ],
      ),
      body: PhoneFrame(
        child: asyncBody(
          tdee,
          onRetry: () => ref.invalidate(tdeeInfoProvider),
          data: (info) => asyncBody(
            me,
            onRetry: () => ref.invalidate(meProvider),
            // Keyed on both payloads so a refetch after saving resets the
            // form to what the server now holds.
            data: (data) => _SettingsForm(
              key: ValueKey((identityHashCode(info), identityHashCode(data))),
              info: info,
              me: data,
              // The language sits above the form rather than inside it: it
              // saves on the tap, while everything below waits for "Lưu".
              header: const _LanguageCard(),
            ),
          ),
        ),
      ),
    );
  }
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

/* -------------------------------------------------------------------------- */
/* Vocabulary                                                                  */
/* -------------------------------------------------------------------------- */

/// Mirrors ACTIVITY_MULTIPLIERS in the backend's nutritionMath.ts. The level
/// describes everyday lifestyle movement only (work, commuting, chores) —
/// logged workout calories are added on top of TDEE separately, so counting
/// sessions here would double them.
/// The multipliers are data and stay const; the wording is localized, so it
/// is looked up per build instead.
const _activityMultipliers = <String, double>{
  'sedentary': 1.2,
  'light': 1.375,
  'moderate': 1.55,
  'active': 1.725,
  'very_active': 1.9,
};

/// Activity level → (label, what an ordinary day looks like).
(String, String) _activityLabel(BuildContext context, String key) =>
    switch (key) {
      'sedentary' => (
        AppL10n.of(context).itVanDong,
        AppL10n.of(context).ngoiLamViecCaNgayIt,
      ),
      'light' => (
        AppL10n.of(context).vanDongNhe,
        AppL10n.of(context).viecNgoiNhieuThinhThoangDi,
      ),
      'moderate' => (
        AppL10n.of(context).vanDongVua,
        AppL10n.of(context).diLaiDiChuyenKhaNhieu,
      ),
      'active' => (
        AppL10n.of(context).nangDong,
        AppL10n.of(context).diDungSuotNgayLaoDong,
      ),
      _ => (
        AppL10n.of(context).ratNangDong,
        AppL10n.of(context).laoDongNangKhuanVacCa,
      ),
    };

/// Goal type → (label, unit the server stores it in). Mirrors GOAL_UNITS in
/// the backend's routes/me.ts.
const _goalUnits = <String, String?>{
  'lose_weight': 'kg',
  'gain_weight': 'kg',
  'gain_muscle': 'kg',
  'reduce_body_fat': 'percent',
  'improve_endurance': 'km',
  'improve_strength': 'kg',
  'sleep_better': 'minutes',
  'manage_condition': null,
};

String _goalLabel(BuildContext context, String key) => switch (key) {
  'lose_weight' => AppL10n.of(context).giamCan,
  'gain_weight' => AppL10n.of(context).tangCan,
  'gain_muscle' => AppL10n.of(context).tangCo,
  'reduce_body_fat' => AppL10n.of(context).giamMo,
  'improve_endurance' => AppL10n.of(context).tangSucBen,
  'improve_strength' => AppL10n.of(context).tangSucManh,
  'sleep_better' => AppL10n.of(context).nguTotHon,
  'manage_condition' => AppL10n.of(context).kiemSoatBenhNen,
  _ => key,
};

String _unitLabel(BuildContext context, String? unit) => switch (unit) {
  'percent' => '%',
  'minutes' => AppL10n.of(context).phut3,
  null => '',
  _ => unit,
};

/// Whole years, the way the backend's ageFromDob counts them.
int _ageOn(DateTime dob, DateTime today) {
  var age = today.year - dob.year;
  if (today.month < dob.month ||
      (today.month == dob.month && today.day < dob.day)) {
    age--;
  }
  return age;
}

String _fmt(double? v, {int digits = 1}) {
  if (v == null) return '';
  return v == v.roundToDouble()
      ? v.toStringAsFixed(0)
      : v.toStringAsFixed(digits);
}

double? _parse(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));

final _kcal = NumberFormat('#,##0');
final _date = DateFormat('dd/MM/yyyy');
final _iso = DateFormat('yyyy-MM-dd');

Set<String> _ids(Object? list) => {
  for (final e in (list as List? ?? const []).whereType<Map>())
    if (e['id'] is String) e['id'] as String,
};

/// A goal as the form holds it: saved ones carry their id, new ones don't
/// until the save bar sends them.
class _GoalDraft {
  const _GoalDraft({
    this.id,
    required this.goalType,
    this.startValue,
    this.targetValue,
    this.deadline,
  });

  factory _GoalDraft.fromGoal(Goal g) => _GoalDraft(
    id: g.id,
    goalType: g.goalType,
    startValue: g.startValue,
    targetValue: g.targetValue,
    deadline: g.deadline,
  );

  final String? id;
  final String goalType;
  final double? startValue;
  final double? targetValue;
  final String? deadline;

  String? get unit => _goalUnits[goalType];

  Object toSignature() => id ?? [goalType, startValue, targetValue, deadline];
}

class _ConditionDraft {
  const _ConditionDraft({this.id, required this.description});

  final String? id;
  final String description;

  Object toSignature() => id ?? description;
}

/* -------------------------------------------------------------------------- */
/* The form                                                                    */
/* -------------------------------------------------------------------------- */

/// Everything on the page is edited locally; nothing reaches the server until
/// the save bar that slides up on the first change is pressed.
/// Account language. Saved the moment it is picked, because the app has to
/// re-render in it to show that anything happened — and because it is the same
/// value the speech recogniser and the assistant read, so leaving it pending
/// behind a "Lưu" would have the three of them disagree in the meantime.
class _LanguageCard extends ConsumerStatefulWidget {
  const _LanguageCard();

  @override
  ConsumerState<_LanguageCard> createState() => _LanguageCardState();
}

class _LanguageCardState extends ConsumerState<_LanguageCard> {
  /// (code, flag, name in that language). The name is not translated — a
  /// language picker that says "Tiếng Việt" only to a Vietnamese reader is
  /// no use to the person trying to get back out of English.
  static List<(String, String, String)> _languages(BuildContext context) =>
      const [
        ('vi', '\u{1F1FB}\u{1F1F3}', 'Tiếng Việt'),
        ('en', '\u{1F1EC}\u{1F1E7}', 'English'),
      ];

  bool _saving = false;

  Future<void> _pick(String locale) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(authControllerProvider.notifier).setLocale(locale);
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
    final current = ref.watch(
      authControllerProvider.select((s) => s.user?.locale ?? 'vi'),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(AppL10n.of(context).ngonNgu),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: RetroBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  AppL10n.of(context).dungChoGiaoDienChoNhan,
                  style: const TextStyle(
                    fontSize: 12,
                    color: RetroTokens.inkSoft,
                  ),
                ),
                const SizedBox(height: 4),
                for (final (code, flag, name) in _languages(context))
                  _LanguageRow(
                    flag: flag,
                    name: name,
                    selected: current == code,
                    busy: _saving,
                    onTap: () => _pick(code),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// One language, picked on the tap. The flag carries the recognition; the
/// tick, not a chip outline, says which one is on — the rest of this screen
/// is rows in a card, and the language belongs in the same shape.
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.flag,
    required this.name,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  final String flag;
  final String name;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: busy ? null : onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Text(flag, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: RetroTokens.ink,
              ),
            ),
          ),
          if (selected)
            const Icon(Icons.check, size: 20, color: RetroTokens.accent),
        ],
      ),
    ),
  );
}

class _SettingsForm extends ConsumerStatefulWidget {
  const _SettingsForm({
    super.key,
    required this.info,
    required this.me,
    this.header,
  });

  final Map<String, dynamic> info;
  final Map<String, dynamic> me;

  /// Settings that save on the spot, above the form's own fields.
  final Widget? header;

  @override
  ConsumerState<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends ConsumerState<_SettingsForm> {
  late final Map<String, dynamic> _inputs =
      (widget.info['inputs'] as Map? ?? const {}).cast<String, dynamic>();

  final _height = TextEditingController();
  final _weight = TextEditingController();
  final _override = TextEditingController();

  String? _sex;
  DateTime? _dob;
  String _activity = 'moderate';
  bool _manual = false;
  List<_GoalDraft> _goals = [];
  List<_ConditionDraft> _conditions = [];

  late String _savedSignature;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Fills every field from the server payload — also what "Đặt lại" does.
  void _load() {
    _sex = _inputs['biologicalSex'] as String?;
    _dob = DateTime.tryParse(_inputs['dateOfBirth'] as String? ?? '');
    _activity = _activityMultipliers.containsKey(_inputs['activityLevel'])
        ? _inputs['activityLevel'] as String
        : 'moderate';
    _height.text = _fmt(_num(_inputs['heightCm']));
    _weight.text = _fmt(_num(_inputs['weightKg']));
    final override = _num(_inputs['dailyCalorieOverrideKcal']);
    _override.text = _fmt(override, digits: 0);
    _manual = override != null;
    // /v1/me names these activeGoals / activeConditions.
    _goals = (widget.me['activeGoals'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Goal.fromJson(e.cast<String, dynamic>()))
        .map(_GoalDraft.fromGoal)
        .toList();
    _conditions = (widget.me['activeConditions'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => ChronicCondition.fromJson(e.cast<String, dynamic>()))
        .map((c) => _ConditionDraft(id: c.id, description: c.description))
        .toList();
    _savedSignature = _signature();
  }

  /// A fingerprint of everything editable; the form is dirty when it differs
  /// from the one taken at load time.
  String _signature() => jsonEncode([
    _sex,
    _dob?.toIso8601String(),
    _activity,
    _height.text.trim(),
    _weight.text.trim(),
    _manual,
    _manual ? _override.text.trim() : null,
    [for (final g in _goals) g.toSignature()],
    [for (final c in _conditions) c.toSignature()],
  ]);

  bool get _dirty => _signature() != _savedSignature;

  @override
  void dispose() {
    _height.dispose();
    _weight.dispose();
    _override.dispose();
    super.dispose();
  }

  int? get _age => _dob == null ? null : _ageOn(_dob!, DateTime.now());

  /// Mifflin-St Jeor, live from whatever is on screen right now.
  double? get _bmr {
    final kg = _parse(_weight.text);
    final cm = _parse(_height.text);
    final age = _age;
    if (kg == null || cm == null || age == null || _sex == null) return null;
    return 10 * kg + 6.25 * cm - 5 * age + (_sex == 'male' ? 5 : -161);
  }

  double get _multiplier => _activityMultipliers[_activity]!;

  double? get _computed => _bmr == null ? null : _bmr! * _multiplier;

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final first = DateTime(now.year - 110);
    final last = DateTime(now.year - 10, now.month, now.day);
    var initial = _dob ?? DateTime(now.year - 25, now.month, now.day);
    // The picker asserts when the initial date is outside its range.
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: AppL10n.of(context).chonNgaySinh,
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _addGoal() async {
    final goal = await showDialog<_GoalDraft>(
      context: context,
      builder: (_) => _GoalDialog(currentWeightKg: _parse(_weight.text)),
    );
    if (goal != null) setState(() => _goals = [..._goals, goal]);
  }

  Future<void> _addCondition() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _ConditionDialog(),
    );
    if (text == null || text.isEmpty) return;
    setState(
      () => _conditions = [..._conditions, _ConditionDraft(description: text)],
    );
  }

  void _reset() => setState(_load);

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppL10n.of(context);
    final kg = _parse(_weight.text);
    final cm = _parse(_height.text);
    final override = _manual ? _parse(_override.text) : null;

    // Same bounds the API enforces, said in words rather than a 400.
    String? problem;
    if (_weight.text.trim().isNotEmpty && (kg == null || kg < 20 || kg > 400)) {
      problem = AppL10n.of(context).canNangPhaiTu20Den;
    } else if (_height.text.trim().isNotEmpty &&
        (cm == null || cm < 80 || cm > 260)) {
      problem = AppL10n.of(context).chieuCaoPhaiTu80Den;
    } else if (_manual &&
        (override == null || override < 800 || override > 6000)) {
      problem = AppL10n.of(context).caloTuNhapPhaiTu800;
    }
    if (problem != null) {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(profileRepositoryProvider);
    try {
      // Weight and height are logs, not profile fields: write a new row only
      // for the ones that actually changed. First, so a new weight goal below
      // snapshots the new weight as its starting point.
      final oldKg = _num(_inputs['weightKg']);
      final oldCm = _num(_inputs['heightCm']);
      final newKg = kg != null && kg != oldKg ? kg : null;
      final newCm = cm != null && cm != oldCm ? cm : null;
      if (newKg != null || newCm != null) {
        await repo.addBodyMetric(weightKg: newKg, heightCm: newCm);
      }
      await repo.patchProfile({
        'biologicalSex': _sex,
        'dateOfBirth': _dob == null ? null : _iso.format(_dob!),
        'activityLevel': _activity,
        'dailyCalorieOverrideKcal': override?.roundToDouble(),
      });

      final keptGoals = {for (final g in _goals) ?g.id};
      for (final id in _ids(widget.me['activeGoals']).difference(keptGoals)) {
        await repo.deleteGoal(id);
      }
      for (final g in _goals.where((g) => g.id == null)) {
        await repo.addGoal(
          goalType: g.goalType,
          targetValue: g.targetValue,
          targetUnit: g.unit,
          deadline: g.deadline,
          startValue: g.startValue ?? 0,
        );
      }

      final keptConditions = {for (final c in _conditions) ?c.id};
      final loadedConditions = _ids(widget.me['activeConditions']);
      for (final id in loadedConditions.difference(keptConditions)) {
        await repo.deleteCondition(id);
      }
      for (final c in _conditions.where((c) => c.id == null)) {
        await repo.addCondition(c.description);
      }

      // Hide the bar now rather than after the refetch lands.
      _savedSignature = _signature();
      messenger.showSnackBar(SnackBar(content: Text(l10n.daLuu)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.saveFailed('$e'))));
    } finally {
      // Also after a failure: part of it may have landed, and the form should
      // show what did.
      ref
        ..invalidate(tdeeInfoProvider)
        ..invalidate(meProvider)
        ..invalidate(goalsProvider)
        ..invalidate(bodyMetricsRangeProvider)
        ..invalidate(allBodyMetricsProvider)
        ..invalidate(dailyNutritionProvider)
        ..invalidate(nutritionRangeProvider);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final computed = _computed;
    final effective = _manual ? _parse(_override.text) : computed;
    final currentKg = _num(_inputs['weightKg']);

    return Stack(
      children: [
        ListView(
          // Room for the save bar, so it never hides the last card.
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            ?widget.header,
            SectionTitle(AppL10n.of(context).thongTinCaNhan),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: RetroBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Label(AppL10n.of(context).gioiTinh),
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: 'male', label: Text('Nam')),
                        ButtonSegment(
                          value: 'female',
                          label: Text(AppL10n.of(context).nu),
                        ),
                      ],
                      selected: {?_sex},
                      emptySelectionAllowed: true,
                      showSelectedIcon: false,
                      onSelectionChanged: (s) =>
                          setState(() => _sex = s.isEmpty ? null : s.first),
                    ),
                    const SizedBox(height: 14),
                    _Label(AppL10n.of(context).ngaySinh),
                    OutlinedButton.icon(
                      onPressed: _pickDob,
                      icon: const Icon(Icons.cake_outlined, size: 18),
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                      ),
                      label: Text(
                        _dob == null
                            ? AppL10n.of(context).chonNgaySinh
                            : AppL10n.of(
                                context,
                              ).dobWithAge(_date.format(_dob!), '$_age'),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _height,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: AppL10n.of(context).chieuCao,
                              suffixText: 'cm',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _weight,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: AppL10n.of(context).canNang,
                              suffixText: 'kg',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      // Keyed so "Đặt lại" repaints the reverted value.
                      key: ValueKey(_activity),
                      initialValue: _activity,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: AppL10n.of(context).mucVanDongHangNgay,
                        helperText: AppL10n.of(
                          context,
                        ).tinhTheoSinhHoatThuongNgay,
                        helperMaxLines: 3,
                      ),
                      items: [
                        for (final key in _activityMultipliers.keys)
                          DropdownMenuItem(
                            value: key,
                            child: Builder(
                              builder: (context) {
                                final (label, detail) = _activityLabel(
                                  context,
                                  key,
                                );
                                return Text(
                                  '$label · $detail',
                                  overflow: TextOverflow.ellipsis,
                                );
                              },
                            ),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _activity = v ?? _activity),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: RetroBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            AppL10n.of(context).caloTieuThuMoiNgay,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _HelpButton(
                          onTap: () => _explain(
                            context,
                            sex: _sex,
                            weightKg: _parse(_weight.text),
                            heightCm: _parse(_height.text),
                            age: _age,
                            bmr: _bmr,
                            activity: _activity,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      effective == null
                          ? '— kcal'
                          : '${_kcal.format(effective)} kcal',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      computed == null
                          ? AppL10n.of(context).dienGioiTinhNgaySinhChieu
                          : AppL10n.of(context).autoTdeeLine(
                              _kcal.format(_bmr),
                              '$_multiplier',
                              _kcal.format(computed),
                              _manual
                                  ? AppL10n.of(context).usingTypedFigure
                                  : '',
                            ),
                      style: const TextStyle(
                        fontSize: 12,
                        color: RetroTokens.inkSoft,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(AppL10n.of(context).tuNhapSoCalo),
                      subtitle: Text(
                        AppL10n.of(context).dungKhiBanBietSoCua,
                        style: TextStyle(fontSize: 12),
                      ),
                      value: _manual,
                      onChanged: (v) => setState(() {
                        _manual = v;
                        if (v && _override.text.isEmpty && computed != null) {
                          _override.text = computed.round().toString();
                        }
                      }),
                    ),
                    if (_manual)
                      TextField(
                        controller: _override,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: AppL10n.of(context).caloTieuThuMoiNgay,
                          suffixText: 'kcal',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SectionTitle(
              AppL10n.of(context).mucTieu,
              action: IconButton(
                tooltip: AppL10n.of(context).themMucTieu,
                icon: const Icon(Icons.add),
                onPressed: _addGoal,
              ),
            ),
            if (_goals.isEmpty)
              _Empty(AppL10n.of(context).chuaDatMucTieuNaoBam),
            for (final goal in _goals)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _GoalTile(
                  goal: goal,
                  currentWeightKg: currentKg,
                  onRemove: () =>
                      setState(() => _goals = [..._goals]..remove(goal)),
                ),
              ),
            SectionTitle(
              AppL10n.of(context).benhNen,
              action: IconButton(
                tooltip: AppL10n.of(context).themBenhNen,
                icon: const Icon(Icons.add),
                onPressed: _addCondition,
              ),
            ),
            if (_conditions.isEmpty)
              _Empty(AppL10n.of(context).khongKhaiBaoBenhNenBam),
            for (final condition in _conditions)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: RetroBox(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          condition.id == null
                              ? AppL10n.of(
                                  context,
                                ).conditionUnsaved(condition.description)
                              : condition.description,
                        ),
                      ),
                      _RemoveButton(
                        onPressed: () => setState(
                          () =>
                              _conditions = [..._conditions]..remove(condition),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: UnsavedChangesBar(
            visible: _dirty || _saving,
            saving: _saving,
            onReset: _reset,
            onSave: _save,
          ),
        ),
      ],
    );
  }
}

/* -------------------------------------------------------------------------- */
/* Small pieces                                                                */
/* -------------------------------------------------------------------------- */

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Text(text, style: const TextStyle(color: RetroTokens.inkFaint)),
  );
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: AppL10n.of(context).xoa,
    visualDensity: VisualDensity.compact,
    icon: const Icon(Icons.close, size: 18, color: RetroTokens.inkSoft),
    onPressed: onPressed,
  );
}

class _GoalTile extends StatelessWidget {
  const _GoalTile({
    required this.goal,
    required this.currentWeightKg,
    required this.onRemove,
  });

  final _GoalDraft goal;
  final double? currentWeightKg;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final unit = _unitLabel(context, goal.unit);
    final isWeight =
        goal.goalType == 'lose_weight' || goal.goalType == 'gain_weight';
    final target = goal.targetValue == null ? '—' : _fmt(goal.targetValue);
    final detail = [
      if (goal.targetValue != null)
        goal.startValue == null
            ? '→ $target $unit'
            : AppL10n.of(
                context,
              ).goalFromTo(_fmt(goal.startValue), target, unit),
      if (goal.deadline != null)
        AppL10n.of(
          context,
        ).goalDeadlineShort(_date.format(DateTime.parse(goal.deadline!))),
      if (goal.id == null) AppL10n.of(context).chuaLuu2,
    ].join(' · ');

    return RetroBox(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _goalLabel(context, goal.goalType),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: const TextStyle(
                      fontSize: 12,
                      color: RetroTokens.inkSoft,
                    ),
                  ),
                if (isWeight && goal.id != null) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: _progress(currentWeightKg),
                    backgroundColor: RetroTokens.paperSunk,
                    color: RetroTokens.accent,
                    minHeight: 8,
                  ),
                ],
              ],
            ),
          ),
          _RemoveButton(onPressed: onRemove),
        ],
      ),
    );
  }

  double _progress(double? current) {
    final start = goal.startValue;
    final target = goal.targetValue;
    if (start == null || target == null || current == null) return 0;
    if (target == start) return 0;
    return ((current - start) / (target - start)).clamp(0, 1).toDouble();
  }
}

/* -------------------------------------------------------------------------- */
/* Dialogs                                                                     */
/* -------------------------------------------------------------------------- */

class _GoalDialog extends StatefulWidget {
  const _GoalDialog({this.currentWeightKg});

  final double? currentWeightKg;

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  String _type = 'lose_weight';
  final _start = TextEditingController();
  final _target = TextEditingController();
  DateTime? _deadline;
  String? _error;

  bool get _hasTarget => _type != 'manage_condition';

  bool get _isWeight => _type == 'lose_weight' || _type == 'gain_weight';

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  /// Weight goals start from the weight on the form; the server snapshots it
  /// again on save anyway.
  void _prefill() {
    _start.text = _isWeight ? _fmt(widget.currentWeightKg) : '';
  }

  @override
  void dispose() {
    _start.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _deadline ?? now.add(const Duration(days: 90)),
      firstDate: now,
      lastDate: DateTime(now.year + 10),
      helpText: AppL10n.of(context).hanHoanThanh,
    );
    if (picked != null) setState(() => _deadline = picked);
  }

  void _submit() {
    final start = _parse(_start.text);
    final target = _parse(_target.text);
    if (_hasTarget && target == null) {
      setState(() => _error = AppL10n.of(context).nhapGiaTriMucTieu);
      return;
    }
    Navigator.of(context).pop(
      _GoalDraft(
        goalType: _type,
        startValue: _hasTarget ? start : null,
        targetValue: _hasTarget ? target : null,
        deadline: _deadline == null ? null : _iso.format(_deadline!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unit = _unitLabel(context, _goalUnits[_type]);
    return AlertDialog(
      title: Text(AppL10n.of(context).themMucTieu),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _type,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: AppL10n.of(context).loaiMucTieu,
              ),
              items: [
                for (final key in _goalUnits.keys)
                  DropdownMenuItem(
                    value: key,
                    child: Text(_goalLabel(context, key)),
                  ),
              ],
              onChanged: (v) => setState(() {
                _type = v ?? _type;
                _error = null;
                _prefill();
              }),
            ),
            if (_hasTarget) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _start,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: AppL10n.of(context).hienTaiKhongBatBuoc,
                  suffixText: unit,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _target,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: AppL10n.of(context).mucTieu,
                  suffixText: unit,
                  errorText: _error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickDeadline,
              icon: const Icon(Icons.event_outlined, size: 18),
              style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
              label: Text(
                _deadline == null
                    ? AppL10n.of(context).hanHoanThanhKhongBatBuoc
                    : AppL10n.of(
                        context,
                      ).goalDeadline(_date.format(_deadline!)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppL10n.of(context).huy),
        ),
        FilledButton(onPressed: _submit, child: Text(AppL10n.of(context).them)),
      ],
    );
  }
}

class _ConditionDialog extends StatefulWidget {
  const _ConditionDialog();

  @override
  State<_ConditionDialog> createState() => _ConditionDialogState();
}

class _ConditionDialogState extends State<_ConditionDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_field.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(AppL10n.of(context).themBenhNen),
    content: TextField(
      controller: _field,
      autofocus: true,
      maxLength: 2000,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: AppL10n.of(context).benhNen,
        hintText: AppL10n.of(context).viDuTieuDuongType2,
        counterText: '',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(AppL10n.of(context).huy),
      ),
      FilledButton(onPressed: _submit, child: Text(AppL10n.of(context).them)),
    ],
  );
}

/// The round "?" that explains where a number comes from.
class _HelpButton extends StatelessWidget {
  const _HelpButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: AppL10n.of(context).viSaoLaiTinhNhuVay,
    child: InkResponse(
      onTap: onTap,
      radius: 18,
      child: Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: RetroTokens.inkSoft),
        ),
        child: const Text(
          '?',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: RetroTokens.inkSoft,
          ),
        ),
      ),
    ),
  );
}

void _explain(
  BuildContext context, {
  required String? sex,
  required double? weightKg,
  required double? heightCm,
  required int? age,
  required double? bmr,
  required String activity,
}) {
  final level = _activityLabel(context, activity);
  final yours = bmr == null
      ? null
      : '10 × ${weightKg!.toStringAsFixed(1)} + 6,25 × '
            '${heightCm!.toStringAsFixed(0)} − 5 × $age '
            '${sex == 'male' ? '+ 5' : '− 161'} = ${_kcal.format(bmr)} kcal\n'
            '${AppL10n.of(context).bmrTimesFactor(_kcal.format(bmr), '${_activityMultipliers[activity]}', level.$1, _kcal.format(bmr * _activityMultipliers[activity]!))}';

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(AppL10n.of(context).viSaoLaiTinhNhuVay),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(AppL10n.of(context).caloTieuThuMoiNgayTdee),
            const SizedBox(height: 10),
            Text(
              AppL10n.of(context).stepOneBmr,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(AppL10n.of(context).mifflinExplainer),
            const SizedBox(height: 10),
            Text(
              AppL10n.of(context).stepTwoActivityFactor,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(AppL10n.of(context).chonTheoMucDoDiChuyen),
            Text(
              [
                for (final key in _activityMultipliers.keys)
                  '• ${_activityLabel(context, key).$1} '
                      '(${_activityLabel(context, key).$2}): '
                      '× ${_activityMultipliers[key]}',
              ].join('\n'),
            ),
            const SizedBox(height: 10),
            Text(AppL10n.of(context).caloCuaCacBuoiTapBan),
            if (yours != null) ...[
              const SizedBox(height: 10),
              Text(
                AppL10n.of(context).voiSoLieuCuaBan,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(yours),
            ],
            const SizedBox(height: 10),
            Text(
              AppL10n.of(context).congThucChiLaUocTinh,
              style: TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppL10n.of(context).daHieu),
        ),
      ],
    ),
  );
}
