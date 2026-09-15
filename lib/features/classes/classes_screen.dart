/// إدارة الصفوف والشعب للسنة الفعّالة.
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db.dart';
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
      body: StreamBuilder<AcademicYear?>(
        stream: db.watchActiveYear(),
        builder: (BuildContext context, AsyncSnapshot<AcademicYear?> ys) {
          final AcademicYear? year = ys.data;
          if (year == null) {
            return const Center(child: Text('لا توجد سنة فعّالة — أنشئها من الإعدادات'));
          }
          return StreamBuilder<List<SchoolClass>>(
            stream: (db.select(db.schoolClasses)
                  ..where((c) => c.yearId.equals(year.id))
                  ..orderBy(<OrderClauseGenerator<SchoolClasses>>[
                    (SchoolClasses c) => OrderingTerm.asc(c.grade),
                    (SchoolClasses c) => OrderingTerm.asc(c.section),
                  ]))
                .watch(),
            builder: (
              BuildContext context,
              AsyncSnapshot<List<SchoolClass>> snap,
            ) {
              final List<SchoolClass> classes = snap.data ?? <SchoolClass>[];
              if (classes.isEmpty) {
                return const Center(child: Text('لا صفوف بعد — أضف أول صف'));
              }
              return ListView.builder(
                itemCount: classes.length,
                itemBuilder: (BuildContext context, int i) {
                  final SchoolClass c = classes[i];
                  return StreamBuilder<int>(
                    stream: (db.selectOnly(db.students)
                          ..addColumns(<Expression<int>>{countAll()})
                          ..where(db.students.classId.equals(c.id)))
                        .map((TypedResult r) => r.read(countAll()) ?? 0)
                        .watchSingle(),
                    builder: (BuildContext context, AsyncSnapshot<int> n) => ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.class_)),
                      title: Text('${c.grade} ـ ${c.section}'),
                      subtitle: Text('طلاب: ${n.data ?? 0}'),
                      onTap: () => context.go(
                        '/students?class=${c.id}'
                        '&title=${Uri.encodeComponent('${c.grade} ـ ${c.section}')}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _edit(context, ref, c),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, SchoolClass? c) async {
    final AppDb db = ref.read(dbProvider);
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return;
    }
    final TextEditingController grade =
        TextEditingController(text: c?.grade ?? '');
    final TextEditingController section =
        TextEditingController(text: c?.section ?? '');
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
    if (ok != true || grade.text.trim().isEmpty || section.text.trim().isEmpty) {
      return;
    }
    if (c == null) {
      final SchoolClass? existing = await (db.select(db.schoolClasses)
            ..where((x) =>
                x.yearId.equals(year.id) &
                x.grade.equals(grade.text.trim()) &
                x.section.equals(section.text.trim())))
          .getSingleOrNull();
      if (existing != null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('الصف والشعبة موجودان مسبقاً')));
        }
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
      await (db.update(db.schoolClasses)..where((x) => x.id.equals(c.id))).write(
        SchoolClassesCompanion(
          grade: Value(grade.text.trim()),
          section: Value(section.text.trim()),
        ),
      );
    }
    await db.logAudit(c == null ? 'class_add' : 'class_edit', grade.text);
  }
}
