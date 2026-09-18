/// السنوات الدراسية: إنشاء/تفعيل/إنهاء/ترقية/تصفير شامل بنسخة إجبارية.
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../data/years_service.dart';
import '../../state/providers.dart';

class YearsScreen extends ConsumerWidget {
  const YearsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('السنوات الدراسية'),
        actions: <Widget>[
          IconButton(
            tooltip: 'سنة جديدة',
            icon: const Icon(Icons.add),
            onPressed: () => _create(context, ref),
          ),
          IconButton(
            tooltip: 'تصفير شامل',
            icon: const Icon(Icons.delete_forever),
            onPressed: () => _reset(context, ref),
          ),
        ],
      ),
      body: StreamBuilder<List<AcademicYear>>(
        stream: (db.select(db.academicYears)
              ..orderBy(<OrderClauseGenerator<AcademicYears>>[
                (AcademicYears y) => OrderingTerm.desc(y.start),
              ]))
            .watch(),
        builder: (BuildContext context, AsyncSnapshot<List<AcademicYear>> snap) {
          final List<AcademicYear> years = snap.data ?? <AcademicYear>[];
          if (years.isEmpty) {
            return const Center(child: Text('لا سنوات — أنشئ سنة من +'));
          }
          return ListView.builder(
            itemCount: years.length,
            itemBuilder: (BuildContext context, int i) {
              final AcademicYear y = years[i];
              return ListTile(
                leading: Icon(
                  y.closed ? Icons.archive : Icons.school,
                  color: y.active ? Colors.teal : Colors.grey,
                ),
                title: Text(y.name),
                subtitle: Text(
                  '${y.start} → ${y.end}'
                  '${y.active ? ' • فعّالة' : ''}${y.closed ? ' • مغلقة' : ''}',
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (String action) async {
                    final YearsService svc = YearsService(ref.read(dbProvider));
                    switch (action) {
                      case 'activate':
                        await svc.activateYear(y.id);
                      case 'close':
                        await svc.closeYear(y.id);
                      case 'promote':
                        await _promote(context, ref, y);
                      case 'delete':
                        // مسارها (تأكيد مزدوج + نسخة إجبارية + رسالة) داخلها.
                        await _deleteYear(context, ref, y);
                    }
                    ref.invalidate(currentYearProvider);
                  },
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                    if (!y.active && !y.closed)
                      const PopupMenuItem<String>(value: 'activate', child: Text('تفعيل')),
                    if (!y.closed)
                      const PopupMenuItem<String>(value: 'close', child: Text('إنهاء السنة')),
                    if (y.closed)
                      const PopupMenuItem<String>(value: 'promote', child: Text('ترقية الطلاب لسنة جديدة')),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: Text(
                        'حذف السنة',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final AppDb db = ref.read(dbProvider);
    DateTime start = DateTime(DateTime.now().year, 9, 1);
    DateTime end = DateTime(DateTime.now().year + 1, 6, 30);
    bool activate = true;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSt) => AlertDialog(
          title: const Text('سنة دراسية جديدة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                title: const Text('البداية'),
                subtitle: Text(SchoolTime.dateKey(start)),
                onTap: () async {
                  final DateTime? d = await showDatePicker(
                    context: context,
                    initialDate: start,
                    firstDate: DateTime(2015),
                    lastDate: DateTime(2045),
                  );
                  if (d != null) {
                    setSt(() => start = d);
                  }
                },
              ),
              ListTile(
                title: const Text('النهاية'),
                subtitle: Text(SchoolTime.dateKey(end)),
                onTap: () async {
                  final DateTime? d = await showDatePicker(
                    context: context,
                    initialDate: end,
                    firstDate: DateTime(2015),
                    lastDate: DateTime(2045),
                  );
                  if (d != null) {
                    setSt(() => end = d);
                  }
                },
              ),
              SwitchListTile(
                value: activate,
                title: const Text('تفعيلها فوراً'),
                onChanged: (bool v) => setSt(() => activate = v),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('إنشاء'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || start.isAfter(end)) {
      return;
    }
    await YearsService(db).createYear(
      name: '${start.year}-${start.year + 1}',
      start: start,
      end: end,
      activate: activate,
    );
    ref.invalidate(currentYearProvider);
  }

  Future<void> _promote(BuildContext context, WidgetRef ref, AcademicYear from) async {
    final AppDb db = ref.read(dbProvider);
    final List<AcademicYear> open = await (db.select(db.academicYears)
          ..where((y) => y.closed.equals(false) & y.id.equals(from.id).not()))
        .get();
    if (open.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('أنشئ سنة جديدة غير مغلقة أولاً')),
        );
      }
      return;
    }
    AcademicYear to = open.first;
    final List<SchoolClass> fromClasses =
        await (db.select(db.schoolClasses)..where((c) => c.yearId.equals(from.id))).get();
    final Map<int, int?> mapping = <int, int?>{
      for (final SchoolClass c in fromClasses) c.id: null,
    };
    if (!context.mounted) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSt) => AlertDialog(
          title: const Text('ترقية الطلاب'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DropdownButtonFormField<AcademicYear>(
                  key: ValueKey<AcademicYear>(to),
                  initialValue: to,
                  items: <DropdownMenuItem<AcademicYear>>[
                    for (final AcademicYear y in open)
                      DropdownMenuItem<AcademicYear>(value: y, child: Text(y.name)),
                  ],
                  onChanged: (AcademicYear? y) {
                    if (y != null) {
                      setSt(() => to = y);
                    }
                  },
                  decoration: const InputDecoration(labelText: 'السنة الوجهة'),
                ),
                FutureBuilder<List<SchoolClass>>(
                  future: (db.select(db.schoolClasses)
                        ..where(
                          (c) => c.yearId.equals(to.id),
                        ))
                      .get(),
                  builder: (
                    BuildContext context,
                    AsyncSnapshot<List<SchoolClass>> snap,
                  ) {
                    final List<SchoolClass> toClasses =
                        snap.data ?? <SchoolClass>[];
                    return Column(
                      children: <Widget>[
                        for (final SchoolClass c in fromClasses)
                          DropdownButtonFormField<int?>(
                            key: ValueKey<int?>(mapping[c.id]),
                            initialValue: mapping[c.id],
                            decoration: InputDecoration(
                              labelText: '${c.grade} ـ ${c.section} ←',
                            ),
                            items: <DropdownMenuItem<int?>>[
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text('لا يُرقّى'),
                              ),
                              for (final SchoolClass t in toClasses)
                                DropdownMenuItem<int?>(
                                  value: t.id,
                                  child: Text('${t.grade} ـ ${t.section}'),
                                ),
                            ],
                            onChanged: (int? v) =>
                                setSt(() => mapping[c.id] = v),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('ترقية'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) {
      return;
    }
    final String school = await db.setting('school_name') ?? '';
    final int yearShort = int.tryParse(to.start.substring(2, 4)) ?? 0;
    final int n = await YearsService(db).promote(
      fromYearId: from.id,
      toYearId: to.id,
      mapping: <int, int>{
        for (final MapEntry<int, int?> e in mapping.entries)
          if (e.value != null) e.key: e.value!,
      },
      schoolName: school,
      yearShort: yearShort,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('رُقّي $n طالباً ببادجات جديدة')));
    }
  }

  /// حذف سنة واحدة بنطاقها الكامل: تأكيد مزدوج كنفس التصفير الشامل، نسخة
  /// احتياطية إجبارية قبل الحذف، ثم رسالة بمسار النسخة. إن كانت آخر سنة
  /// يعود التطبيق لشاشة الإعداد الأولي.
  Future<void> _deleteYear(
    BuildContext context,
    WidgetRef ref,
    AcademicYear y,
  ) async {
    final bool? sure1 = await _confirm(
      context,
      'حذف السنة ${y.name}',
      'سيُحذف كل ما يخص هذه السنة وحدها: صفوفها وطلابها وصورهم، '
      'الحضور والإجازات والجلسات والبادجات — وبقية السنوات لا تُمس. '
      'سيُنشأ ملف نسخ احتياطي إجباري أولاً.',
    );
    if (sure1 != true) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    final bool? sure2 = await _confirm(
      context,
      'تأكيد أخير',
      'هل فهمت أن بيانات السنة ${y.name} ستُمحى من التطبيق '
      'بعد حفظ النسخة الاحتياطية؟',
    );
    if (sure2 != true) {
      return;
    }
    final AppDb db = ref.read(dbProvider);
    try {
      final String backup = await YearsService(db).deleteYear(y.id);
      ref.invalidate(currentYearProvider);
      ref.invalidate(yearEndedProvider);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('حُذفت السنة ${y.name}. النسخة الاحتياطية: $backup'),
        ),
      );
      final int remaining = await (db.selectOnly(db.academicYears)
            ..addColumns(<Expression<int>>[countAll()]))
          .map((TypedResult r) => r.read(countAll()) ?? 0)
          .getSingle();
      if (remaining == 0 && context.mounted) {
        // لا سنوات إطلاقاً: العودة للإعداد الأولي كما بعد التصفير الشامل.
        context.go('/onboarding');
      }
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'years:deleteYear');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حذف السنة: $e')),
        );
      }
    }
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final bool? sure1 = await _confirm(
      context,
      'تصفير شامل',
      'سيُمحى كل شيء (طلاب، حضور، سنوات). سيُنشأ ملف نسخ احتياطي إجباري أولاً.',
    );
    if (sure1 != true) {
      return;
    }
    if (!context.mounted) {
      return;
    }
    final bool? sure2 = await _confirm(
      context,
      'تأكيد أخير',
      'هل فهمت أن البيانات ستُمحى من التطبيق بعد حفظ النسخة الاحتياطية؟',
    );
    if (sure2 != true) {
      return;
    }
    final String backup = await YearsService(ref.read(dbProvider)).resetAll();
    ref.invalidate(settingsProvider);
    ref.invalidate(effectiveSettingsProvider);
    ref.invalidate(currentYearProvider);
    ref.invalidate(yearEndedProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم التصفير. النسخة الاحتياطية: $backup')),
      );
      // لا بيانات بعد التصفير: العودة للإعداد الأولي.
      context.go('/onboarding');
    }
  }

  Future<bool?> _confirm(BuildContext context, String title, String body) =>
      showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('تراجع'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('تأكيد'),
            ),
          ],
        ),
      );
}
