/// إدارة الصفوف والشعب للسنة الفعّالة.
///
/// التنقّل إلى الطلاب يمرّ عبر [AppRoutes.classLocation] (ترميز صحيح للمعاملات)
/// ومع `extra: ClassRef` حتى لا تعتمد الشاشة الوجهة على سلامة الرابط إطلاقاً.
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error_guard.dart';
import '../../core/nav.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../state/providers.dart';

class ClassesScreen extends ConsumerWidget {
  const ClassesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('الصفوف والشعب')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('صف جديد'),
      ),
      body: StreamGuard<AcademicYear?>(
        stream: db.watchActiveYear(),
        builder: (BuildContext context, AcademicYear? year) {
          if (year == null) {
            return const Center(
              child: Text('لا توجد سنة فعّالة — أنشئها من شاشة السنوات'),
            );
          }
          return StreamGuard<List<SchoolClass>>(
            stream: (db.select(db.schoolClasses)
                  ..where((c) => c.yearId.equals(year.id))
                  ..orderBy(<OrderClauseGenerator<SchoolClasses>>[
                    (SchoolClasses c) => OrderingTerm.asc(c.grade),
                    (SchoolClasses c) => OrderingTerm.asc(c.section),
                  ]))
                .watch(),
            builder: (BuildContext context, List<SchoolClass> classes) {
              if (classes.isEmpty) {
                return const Center(child: Text('لا صفوف بعد — أضف أول صف'));
              }
              return ListView.builder(
                itemCount: classes.length,
                itemBuilder: (BuildContext context, int i) =>
                    _classTile(context, ref, db, classes[i]),
              );
            },
          );
        },
      ),
    );
  }

  Widget _classTile(
    BuildContext context,
    WidgetRef ref,
    AppDb db,
    SchoolClass c,
  ) {
    final String title = '${c.grade} ـ ${c.section}';
    return StreamGuard<int>(
      stream: (db.selectOnly(db.students)
            ..addColumns(<Expression<int>>[countAll()])
            ..where(db.students.classId.equals(c.id)))
          .map((TypedResult r) => r.read(countAll()) ?? 0)
          .watchSingle(),
      loading: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.class_)),
        title: Text(title),
        subtitle: const Text('طلاب: …'),
      ),
      builder: (BuildContext context, int count) => ListTile(
        leading: const CircleAvatar(child: Icon(Icons.class_)),
        title: Text(title),
        subtitle: Text('طلاب: $count'),
        onTap: () => context.push(
          AppRoutes.classLocation('/students', c.id, title),
          extra: ClassRef(id: c.id, title: title),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              tooltip: 'البادجات',
              icon: const Icon(Icons.badge),
              onPressed: () => context.push(
                AppRoutes.classLocation('/badges', c.id, title),
                extra: ClassRef(id: c.id, title: title),
              ),
            ),
            IconButton(
              tooltip: 'كشف اليوم',
              icon: const Icon(Icons.fact_check),
              onPressed: () => context.push(
                AppRoutes.classLocation('/day-sheet', c.id, title),
                extra: ClassRef(id: c.id, title: title),
              ),
            ),
            IconButton(
              tooltip: 'تعديل',
              icon: const Icon(Icons.edit),
              onPressed: () => _edit(context, ref, c),
            ),
            IconButton(
              tooltip: 'حذف',
              icon: const Icon(Icons.delete),
              onPressed: () => _delete(context, ref, c),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, SchoolClass? c) async {
    final AppDb db = ref.read(dbProvider);
    AcademicYear? year;
    try {
      year = await db.activeYear();
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'classes:year');
      _snack(context, 'تعذر قراءة السنة الفعّالة: $e');
      return;
    }
    if (year == null) {
      _snack(context, 'لا توجد سنة فعّالة — أنشئها من شاشة السنوات');
      return;
    }
    final TextEditingController grade =
        TextEditingController(text: c?.grade ?? '');
    final TextEditingController section =
        TextEditingController(text: c?.section ?? '');
    if (!context.mounted) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(c == null ? 'إضافة صف' : 'تعديل صف'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: grade,
              decoration: const InputDecoration(labelText: 'الصف (مثال: السادس)'),
            ),
            TextField(
              controller: section,
              decoration: const InputDecoration(labelText: 'الشعبة (مثال: أ)'),
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
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    if (grade.text.trim().isEmpty || section.text.trim().isEmpty) {
      _snack(context, 'اكتب الصف والشعبة معاً');
      return;
    }
    try {
      if (c == null) {
        final SchoolClass? existing = await (db.select(db.schoolClasses)
              ..where(
                (x) =>
                    x.yearId.equals(year!.id) &
                    x.grade.equals(grade.text.trim()) &
                    x.section.equals(section.text.trim()),
              ))
            .getSingleOrNull();
        if (existing != null) {
          _snack(context, 'الصف والشعبة موجودان مسبقاً');
          return;
        }
        await db.into(db.schoolClasses).insert(
              SchoolClassesCompanion(
                yearId: Value(year.id),
                grade: Value(grade.text.trim()),
                section: Value(section.text.trim()),
              ),
            );
      } else {
        await (db.update(db.schoolClasses)..where((x) => x.id.equals(c.id)))
            .write(
          SchoolClassesCompanion(
            grade: Value(grade.text.trim()),
            section: Value(section.text.trim()),
          ),
        );
      }
      await db.logAudit(c == null ? 'class_add' : 'class_edit', grade.text);
      _snack(context, c == null ? 'أُضيف الصف' : 'حُفظ التعديل');
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'classes:save');
      _snack(context, 'تعذر الحفظ: $e');
    }
  }

  /// حذف صف فارغ فقط؛ الصف الذي فيه طلاب يُوجَّه لحذفهم أولاً (حماية البيانات).
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    SchoolClass c,
  ) async {
    final AppDb db = ref.read(dbProvider);
    int kids;
    try {
      kids = await db.countStudentsInClass(c.id);
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'classes:count');
      _snack(context, 'تعذر فحص الصف: $e');
      return;
    }
    if (!context.mounted) {
      return;
    }
    if (kids > 0) {
      _snack(context, 'الصف فيه $kids طالباً — احذف الطلاب أو رقّهم أولاً');
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('حذف صف'),
        content: Text('سيُحذف «${c.grade} ـ ${c.section}» وجلساته. متابعة؟'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    try {
      await db.deleteClass(c.id);
      _snack(context, 'حُذف الصف');
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'classes:delete');
      _snack(context, 'تعذر الحذف: $e');
    }
  }
}

void _snack(BuildContext context, String message) {
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
