/// الإعداد الأولي: اسم المدرسة، المدير، بداية/نهاية السنة الدراسية.
library;

import 'package:flutter/material.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../state/providers.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingState();
}

class _OnboardingState extends ConsumerState<OnboardingScreen> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _school = TextEditingController();
  final TextEditingController _director = TextEditingController();
  DateTime _start = DateTime(DateTime.now().year, 9, 1);
  DateTime _end = DateTime(DateTime.now().year + 1, 6, 30);
  bool _saving = false;

  Future<void> _pick(bool isStart) async {
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: isStart ? _start : _end,
      firstDate: DateTime(2015),
      lastDate: DateTime(2040),
    );
    if (d != null) {
      setState(() {
        if (isStart) {
          _start = d;
        } else {
          _end = d;
        }
      });
    }
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    final AppDb db = ref.read(dbProvider);
    final String yearName =
        '${_start.year}-${_start.year + 1}';
    await db.into(db.academicYears).insert(
          AcademicYearsCompanion(
            name: Value(yearName),
            start: Value(SchoolTime.dateKey(_start)),
            end: Value(SchoolTime.dateKey(_end)),
            active: const Value(true),
          ),
        );
    await db.setSetting('school_name', _school.text.trim());
    await db.setSetting('director_name', _director.text.trim());
    await db.setSetting(
      'work_weekdays',
      SchoolTime.defaultWorkWeekdays.join(','),
    );
    await db.setSetting('show_hijri', '1');
    await db.setSetting('alert_threshold_1', '10');
    await db.setSetting('alert_threshold_2', '15');
    await db.logAudit('onboarding', yearName);
    ref.invalidate(settingsProvider);
    ref.invalidate(effectiveSettingsProvider);
    ref.invalidate(currentYearProvider);
    ref.invalidate(yearEndedProvider);
    if (mounted) {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('الإعداد الأولي')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'مرحباً بك في «حضور الطالب».\n'
                        'أدخل معلومات المدرسة لتوليد البادجات والتقارير باسمها.',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _school,
                    decoration: const InputDecoration(
                      labelText: 'اسم المدرسة',
                      border: OutlineInputBorder(),
                    ),
                    validator: (String? v) =>
                        (v == null || v.trim().length < 3) ? 'أدخل اسم المدرسة' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _director,
                    decoration: const InputDecoration(
                      labelText: 'اسم المدير',
                      border: OutlineInputBorder(),
                    ),
                    validator: (String? v) =>
                        (v == null || v.trim().length < 3) ? 'أدخل اسم المدير' : null,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _DateField(
                          label: 'بداية السنة الدراسية',
                          value: _start,
                          onTap: () => _pick(true),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _DateField(
                          label: 'نهاية السنة الدراسية',
                          value: _end,
                          onTap: () => _pick(false),
                        ),
                      ),
                    ],
                  ),
                  if (_start.isAfter(_end))
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'تنبيه: تاريخ البداية بعد النهاية — صحّح قبل الحفظ',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: (_saving || _start.isAfter(_end)) ? null : _save,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ وبدء الاستخدام'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          child: Text(SchoolTime.dateKey(value)),
        ),
      );
}
