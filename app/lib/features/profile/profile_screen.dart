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
        title: const Text('Cá nhân'),
        actions: [
          TextButton(
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
            child: const Text('Đăng xuất'),
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

/// Mirrors ACTIVITY_MULTIPLIERS in the backend's nutritionMath.ts.
const _activityLevels = <String, (String, String, double)>{
  'sedentary': ('Ít vận động', 'Ngồi nhiều, hầu như không tập', 1.2),
  'light': ('Vận động nhẹ', 'Tập 1–3 buổi/tuần', 1.375),
  'moderate': ('Vận động vừa', 'Tập 3–5 buổi/tuần', 1.55),
  'active': ('Năng động', 'Tập 6–7 buổi/tuần', 1.725),
  'very_active': ('Rất năng động', 'Lao động nặng hoặc tập 2 lần/ngày', 1.9),
};

/// Goal type → (label, unit the server stores it in). Mirrors GOAL_UNITS in
/// the backend's routes/me.ts.
const _goalTypes = <String, (String, String?)>{
  'lose_weight': ('Giảm cân', 'kg'),
  'gain_weight': ('Tăng cân', 'kg'),
  'gain_muscle': ('Tăng cơ', 'kg'),
  'reduce_body_fat': ('Giảm mỡ', 'percent'),
  'improve_endurance': ('Tăng sức bền', 'km'),
  'improve_strength': ('Tăng sức mạnh', 'kg'),
  'sleep_better': ('Ngủ tốt hơn', 'minutes'),
  'manage_condition': ('Kiểm soát bệnh nền', null),
};

String _unitLabel(String? unit) => switch (unit) {
  'percent' => '%',
  'minutes' => 'phút',
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

  String? get unit => _goalTypes[goalType]?.$2;

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
class _SettingsForm extends ConsumerStatefulWidget {
  const _SettingsForm({super.key, required this.info, required this.me});

  final Map<String, dynamic> info;
  final Map<String, dynamic> me;

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
    _activity = _activityLevels.containsKey(_inputs['activityLevel'])
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

  double get _multiplier => _activityLevels[_activity]!.$3;

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
      helpText: 'Chọn ngày sinh',
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
    final kg = _parse(_weight.text);
    final cm = _parse(_height.text);
    final override = _manual ? _parse(_override.text) : null;

    // Same bounds the API enforces, said in words rather than a 400.
    String? problem;
    if (_weight.text.trim().isNotEmpty && (kg == null || kg < 20 || kg > 400)) {
      problem = 'Cân nặng phải từ 20 đến 400 kg';
    } else if (_height.text.trim().isNotEmpty &&
        (cm == null || cm < 80 || cm > 260)) {
      problem = 'Chiều cao phải từ 80 đến 260 cm';
    } else if (_manual &&
        (override == null || override < 800 || override > 6000)) {
      problem = 'Calo tự nhập phải từ 800 đến 6.000 kcal';
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
      messenger.showSnackBar(const SnackBar(content: Text('Đã lưu')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Không lưu được: $e')));
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
            const SectionTitle('Thông tin cá nhân'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: RetroBox(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Label('Giới tính'),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'male', label: Text('Nam')),
                        ButtonSegment(value: 'female', label: Text('Nữ')),
                      ],
                      selected: {?_sex},
                      emptySelectionAllowed: true,
                      showSelectedIcon: false,
                      onSelectionChanged: (s) =>
                          setState(() => _sex = s.isEmpty ? null : s.first),
                    ),
                    const SizedBox(height: 14),
                    const _Label('Ngày sinh'),
                    OutlinedButton.icon(
                      onPressed: _pickDob,
                      icon: const Icon(Icons.cake_outlined, size: 18),
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                      ),
                      label: Text(
                        _dob == null
                            ? 'Chọn ngày sinh'
                            : '${_date.format(_dob!)} · $_age tuổi',
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
                            decoration: const InputDecoration(
                              labelText: 'Chiều cao',
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
                            decoration: const InputDecoration(
                              labelText: 'Cân nặng',
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
                      decoration: const InputDecoration(
                        labelText: 'Mức vận động',
                      ),
                      items: [
                        for (final e in _activityLevels.entries)
                          DropdownMenuItem(
                            value: e.key,
                            child: Text(
                              '${e.value.$1} · ${e.value.$2}',
                              overflow: TextOverflow.ellipsis,
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
                        const Expanded(
                          child: Text(
                            'Calo tiêu thụ mỗi ngày',
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
                          ? 'Điền giới tính, ngày sinh, chiều cao và cân nặng '
                                'để app tự tính.'
                          : 'Tự tính: BMR ${_kcal.format(_bmr)} × '
                                '$_multiplier = ${_kcal.format(computed)} kcal'
                                '${_manual ? ' (đang dùng số bạn nhập)' : ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: RetroTokens.inkSoft,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Tự nhập số calo'),
                      subtitle: const Text(
                        'Dùng khi bạn biết số của mình, ví dụ từ đồng hồ '
                        'thông minh hoặc chuyên gia dinh dưỡng.',
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
                        decoration: const InputDecoration(
                          labelText: 'Calo tiêu thụ mỗi ngày',
                          suffixText: 'kcal',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SectionTitle(
              'Mục tiêu',
              action: IconButton(
                tooltip: 'Thêm mục tiêu',
                icon: const Icon(Icons.add),
                onPressed: _addGoal,
              ),
            ),
            if (_goals.isEmpty)
              const _Empty('Chưa đặt mục tiêu nào. Bấm + để thêm.'),
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
              'Bệnh nền',
              action: IconButton(
                tooltip: 'Thêm bệnh nền',
                icon: const Icon(Icons.add),
                onPressed: _addCondition,
              ),
            ),
            if (_conditions.isEmpty)
              const _Empty('Không khai báo bệnh nền. Bấm + để thêm.'),
            for (final condition in _conditions)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: RetroBox(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          condition.id == null
                              ? '${condition.description} · chưa lưu'
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
    tooltip: 'Xoá',
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
    final unit = _unitLabel(goal.unit);
    final isWeight =
        goal.goalType == 'lose_weight' || goal.goalType == 'gain_weight';
    final target = goal.targetValue == null ? '—' : _fmt(goal.targetValue);
    final detail = [
      if (goal.targetValue != null)
        goal.startValue == null
            ? '→ $target $unit'
            : 'từ ${_fmt(goal.startValue)} → $target $unit',
      if (goal.deadline != null)
        'hạn ${_date.format(DateTime.parse(goal.deadline!))}',
      if (goal.id == null) 'chưa lưu',
    ].join(' · ');

    return RetroBox(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _goalTypes[goal.goalType]?.$1 ?? goal.goalType,
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
      helpText: 'Hạn hoàn thành',
    );
    if (picked != null) setState(() => _deadline = picked);
  }

  void _submit() {
    final start = _parse(_start.text);
    final target = _parse(_target.text);
    if (_hasTarget && target == null) {
      setState(() => _error = 'Nhập giá trị mục tiêu');
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
    final unit = _unitLabel(_goalTypes[_type]!.$2);
    return AlertDialog(
      title: const Text('Thêm mục tiêu'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _type,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Loại mục tiêu'),
              items: [
                for (final e in _goalTypes.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value.$1)),
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
                  labelText: 'Hiện tại (không bắt buộc)',
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
                  labelText: 'Mục tiêu',
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
                    ? 'Hạn hoàn thành (không bắt buộc)'
                    : 'Hạn: ${_date.format(_deadline!)}',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Huỷ'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Thêm')),
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
    title: const Text('Thêm bệnh nền'),
    content: TextField(
      controller: _field,
      autofocus: true,
      maxLength: 2000,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      decoration: const InputDecoration(
        labelText: 'Bệnh nền',
        hintText: 'Ví dụ: tiểu đường type 2, cao huyết áp',
        counterText: '',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Huỷ'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Thêm')),
    ],
  );
}

/// The round "?" that explains where a number comes from.
class _HelpButton extends StatelessWidget {
  const _HelpButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Vì sao lại tính như vậy?',
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
  final level = _activityLevels[activity]!;
  final yours = bmr == null
      ? null
      : '10 × ${weightKg!.toStringAsFixed(1)} + 6,25 × '
            '${heightCm!.toStringAsFixed(0)} − 5 × $age '
            '${sex == 'male' ? '+ 5' : '− 161'} = ${_kcal.format(bmr)} kcal\n'
            '${_kcal.format(bmr)} × ${level.$3} (${level.$1}) = '
            '${_kcal.format(bmr * level.$3)} kcal/ngày';

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Vì sao lại tính như vậy?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Calo tiêu thụ mỗi ngày (TDEE) là năng lượng cơ thể bạn đốt '
              'trong 24 giờ. App ước tính theo 2 bước:',
            ),
            const SizedBox(height: 10),
            const Text(
              '1. BMR — năng lượng đốt khi nằm nghỉ hoàn toàn',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const Text(
              'Dùng công thức Mifflin-St Jeor, được khuyên dùng vì cho sai số '
              'thấp nhất ở người trưởng thành:\n'
              '• Nam: 10 × cân nặng (kg) + 6,25 × chiều cao (cm) − 5 × tuổi + 5\n'
              '• Nữ: 10 × cân nặng (kg) + 6,25 × chiều cao (cm) − 5 × tuổi − 161\n'
              'Nam có nhiều cơ hơn nên đốt nhiều hơn; tuổi càng cao cơ thể '
              'đốt càng ít.',
            ),
            const SizedBox(height: 10),
            const Text(
              '2. Nhân với hệ số vận động',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(
              [
                for (final l in _activityLevels.values)
                  '• ${l.$1} (${l.$2}): × ${l.$3}',
              ].join('\n'),
            ),
            const SizedBox(height: 10),
            const Text(
              'Calo của các buổi tập bạn ghi lại được cộng thêm vào đúng '
              'ngày đó.',
            ),
            if (yours != null) ...[
              const SizedBox(height: 10),
              const Text(
                'Với số liệu của bạn',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(yours),
            ],
            const SizedBox(height: 10),
            const Text(
              'Công thức chỉ là ước tính (lệch khoảng ±10%). Nếu bạn biết số '
              'chính xác hơn, hãy bật "Tự nhập số calo" — app sẽ dùng số đó '
              'thay cho công thức. Mục tiêu calo, đạm, tinh bột và chất béo '
              'trên trang chủ đều tính từ con số này.',
              style: TextStyle(fontSize: 12, color: RetroTokens.inkSoft),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Đã hiểu'),
        ),
      ],
    ),
  );
}
