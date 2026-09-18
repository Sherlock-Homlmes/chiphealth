import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/retro_widgets.dart';
import 'log_weight_sheet.dart';

final meProvider = FutureProvider<Map<String, dynamic>>(
  (ref) => ref.watch(profileRepositoryProvider).me(),
);

final bodyMetricsProvider = FutureProvider<List<BodyMetric>>(
  (ref) => ref.watch(profileRepositoryProvider).bodyMetrics(),
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
    final metrics = ref.watch(bodyMetricsProvider);

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
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(meProvider);
          ref.invalidate(tdeeInfoProvider);
          ref.invalidate(bodyMetricsProvider);
        },
        child: PhoneFrame(
          child: ListView(
            children: [
              const SectionTitle('Thông tin cá nhân'),
              asyncBody(
                tdee,
                onRetry: () => ref.invalidate(tdeeInfoProvider),
                // Keyed on the payload so a refetch after saving resets the
                // form to what the server now holds.
                data: (info) =>
                    _PersonalInfoForm(key: ObjectKey(info), info: info),
              ),
              SectionTitle(
                'Lịch sử cân nặng',
                action: IconButton(
                  tooltip: 'Ghi cân nặng',
                  icon: const Icon(Icons.add),
                  onPressed: () => logWeight(
                    context,
                    ref,
                    current: _num(
                      (tdee.valueOrNull?['inputs'] as Map?)?['weightKg'],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: asyncBody(
                  metrics,
                  emptyWhen: (list) =>
                      list.where((m) => m.weightKg != null).length < 2,
                  emptyText: 'Ghi thêm vài lần cân để thấy biểu đồ.',
                  data: (list) =>
                      RetroBox(child: _WeightSparkline(metrics: list)),
                ),
              ),
              asyncBody(
                me,
                onRetry: () => ref.invalidate(meProvider),
                data: (data) => _GoalsAndConditions(
                  data: data,
                  currentWeightKg: _num(
                    (tdee.valueOrNull?['inputs'] as Map?)?['weightKg'],
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

/* -------------------------------------------------------------------------- */
/* Personal details + daily energy                                             */
/* -------------------------------------------------------------------------- */

/// Mirrors ACTIVITY_MULTIPLIERS in the backend's nutritionMath.ts.
const _activityLevels = <String, (String, String, double)>{
  'sedentary': ('Ít vận động', 'Ngồi nhiều, hầu như không tập', 1.2),
  'light': ('Vận động nhẹ', 'Tập 1–3 buổi/tuần', 1.375),
  'moderate': ('Vận động vừa', 'Tập 3–5 buổi/tuần', 1.55),
  'active': ('Năng động', 'Tập 6–7 buổi/tuần', 1.725),
  'very_active': ('Rất năng động', 'Lao động nặng hoặc tập 2 lần/ngày', 1.9),
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

class _PersonalInfoForm extends ConsumerStatefulWidget {
  const _PersonalInfoForm({super.key, required this.info});

  final Map<String, dynamic> info;

  @override
  ConsumerState<_PersonalInfoForm> createState() => _PersonalInfoFormState();
}

class _PersonalInfoFormState extends ConsumerState<_PersonalInfoForm> {
  late final Map<String, dynamic> _inputs =
      (widget.info['inputs'] as Map? ?? const {}).cast<String, dynamic>();

  late String? _sex = _inputs['biologicalSex'] as String?;
  late DateTime? _dob = DateTime.tryParse(
    _inputs['dateOfBirth'] as String? ?? '',
  );
  late String _activity = _activityLevels.containsKey(_inputs['activityLevel'])
      ? _inputs['activityLevel'] as String
      : 'moderate';
  late final _height = TextEditingController(
    text: _fmt(_num(_inputs['heightCm'])),
  );
  late final _weight = TextEditingController(
    text: _fmt(_num(_inputs['weightKg'])),
  );
  late final _override = TextEditingController(
    text: _fmt(_num(_inputs['dailyCalorieOverrideKcal']), digits: 0),
  );
  late bool _manual = _num(_inputs['dailyCalorieOverrideKcal']) != null;
  bool _saving = false;

  static final _kcal = NumberFormat('#,##0');
  static final _date = DateFormat('dd/MM/yyyy');

  static String _fmt(double? v, {int digits = 1}) {
    if (v == null) return '';
    return v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(digits);
  }

  static double? _parse(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

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
      // for the ones that actually changed.
      final oldKg = _num(_inputs['weightKg']);
      final oldCm = _num(_inputs['heightCm']);
      final newKg = kg != null && kg != oldKg ? kg : null;
      final newCm = cm != null && cm != oldCm ? cm : null;
      if (newKg != null || newCm != null) {
        await repo.addBodyMetric(weightKg: newKg, heightCm: newCm);
      }
      await repo.patchProfile({
        'biologicalSex': _sex,
        'dateOfBirth': _dob == null
            ? null
            : DateFormat('yyyy-MM-dd').format(_dob!),
        'activityLevel': _activity,
        'dailyCalorieOverrideKcal': override?.roundToDouble(),
      });
      ref
        ..invalidate(tdeeInfoProvider)
        ..invalidate(meProvider)
        ..invalidate(bodyMetricsProvider)
        ..invalidate(bodyMetricsRangeProvider)
        ..invalidate(allBodyMetricsProvider)
        ..invalidate(dailyNutritionProvider)
        ..invalidate(nutritionRangeProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('Đã lưu thông tin cá nhân')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Không lưu được: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final computed = _computed;
    final effective = _manual ? _parse(_override.text) : computed;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RetroBox(
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
                  initialValue: _activity,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Mức vận động'),
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
                  onChanged: (v) => setState(() => _activity = v ?? _activity),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          RetroBox(
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
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  computed == null
                      ? 'Điền giới tính, ngày sinh, chiều cao và cân nặng để '
                            'app tự tính.'
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
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Đang lưu…' : 'Lưu thông tin'),
          ),
        ],
      ),
    );
  }
}

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
  final kcal = NumberFormat('#,##0');
  final level = _activityLevels[activity]!;
  final yours = bmr == null
      ? null
      : '10 × ${weightKg!.toStringAsFixed(1)} + 6,25 × '
            '${heightCm!.toStringAsFixed(0)} − 5 × $age '
            '${sex == 'male' ? '+ 5' : '− 161'} = ${kcal.format(bmr)} kcal\n'
            '${kcal.format(bmr)} × ${level.$3} (${level.$1}) = '
            '${kcal.format(bmr * level.$3)} kcal/ngày';

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

/* -------------------------------------------------------------------------- */
/* Goals + conditions                                                          */
/* -------------------------------------------------------------------------- */

class _GoalsAndConditions extends StatelessWidget {
  const _GoalsAndConditions({required this.data, this.currentWeightKg});

  final Map<String, dynamic> data;
  final double? currentWeightKg;

  @override
  Widget build(BuildContext context) {
    // /v1/me names these activeGoals / activeConditions.
    final goals = (data['activeGoals'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Goal.fromJson(e.cast<String, dynamic>()))
        .toList();
    final conditions = (data['activeConditions'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => ChronicCondition.fromJson(e.cast<String, dynamic>()))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Mục tiêu'),
        if (goals.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Chưa đặt mục tiêu nào.',
              style: TextStyle(color: RetroTokens.inkFaint),
            ),
          ),
        for (final goal in goals)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: RetroBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _goalLabel(goal.goalType),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'từ ${goal.startValue.toStringAsFixed(1)} → '
                    '${goal.targetValue?.toStringAsFixed(1) ?? '—'} ${goal.targetUnit ?? ''}'
                    '${goal.deadline != null ? ' · hạn ${goal.deadline}' : ''}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: RetroTokens.inkSoft,
                    ),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: goal.progress(currentWeightKg),
                    backgroundColor: RetroTokens.paperSunk,
                    color: RetroTokens.accent,
                    minHeight: 8,
                  ),
                ],
              ),
            ),
          ),
        const SectionTitle('Bệnh nền'),
        if (conditions.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Không khai báo bệnh nền.',
              style: TextStyle(color: RetroTokens.inkFaint),
            ),
          ),
        for (final condition in conditions)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: RetroBox(child: Text(condition.description)),
          ),
      ],
    );
  }
}

String _goalLabel(String type) => switch (type) {
  'lose_weight' => 'Giảm cân',
  'gain_weight' => 'Tăng cân',
  'gain_muscle' => 'Tăng cơ',
  'reduce_body_fat' => 'Giảm mỡ',
  'improve_endurance' => 'Tăng sức bền',
  'improve_strength' => 'Tăng sức mạnh',
  'sleep_better' => 'Ngủ tốt hơn',
  _ => 'Kiểm soát bệnh nền',
};

/// Weight over time. A sparkline rather than a full chart: the trend is the
/// message, and the exact numbers are one tap away.
class _WeightSparkline extends StatelessWidget {
  const _WeightSparkline({required this.metrics});

  final List<BodyMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final points = metrics.where((m) => m.weightKg != null).toList()
      ..sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    if (points.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 80,
      child: CustomPaint(
        painter: _SparklinePainter(points.map((p) => p.weightKg!).toList()),
        size: Size.infinite,
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values);

  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final span = (max - min).abs() < 0.01 ? 1.0 : max - min;

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * (i / (values.length - 1));
      final y = size.height - ((values[i] - min) / span) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = RetroTokens.accent
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.values != values;
}
