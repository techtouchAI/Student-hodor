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

class ClassesScreen extends ConsumerStatefulWidget {
  const ClassesScreen({super.key});

  @override
  ConsumerState<ClassesScreen> createState() => _ClassesState();
}

class _ClassesState extends ConsumerState<ClassesScreen> {
  /// رسالة snackbar — تُستدعى دائماً بعد حارس `mounted` فلا يُستخدم
  /// `context` عبر فجوة `async`.
  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('الصفوف والشعب')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
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
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: classes.length,
                itemBuilder: (BuildContext context, int i) =>
                    _classTile(db, classes[i]),
              );
            },
          );
        },
      ),
    );
  }

  Widget _classTile(AppDb db, SchoolClass c) {
    final String title = '${c.grade} ـ ${c.section}';
    final ClassRef ref0 = ClassRef(id: c.id, title: title);
    return StreamGuard<int>(
      stream: (db.selectOnly(db.students)
            ..addColumns(<Expression<int>>[countAll()])
            ..where(db.students.classId.equals(c.id)))
          .map((TypedResult r) => r.read(countAll()) ?? 0)
          .watchSingle(),
      loading: _classCard(
        title: title,
        countText: 'طلاب: …',
        c: c,
        ref0: ref0,
      ),
      builder: (BuildContext context, int count) => _classCard(
        title: title,
        countText: 'طلاب: $count',
        c: c,
        ref0: ref0,
      ),
    );
  }

  Widget _classCard({
    required String title,
    required String countText,
    required SchoolClass c,
    required ClassRef ref0,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0.5,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(
          AppRoutes.classLocation('/students', c.id, title),
          extra: ref0,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // السطر الأول: الأيقونة واسم الصف كاملاً دون تزاحم
              Row(
                children: <Widget>[
                  const CircleAvatar(
                    radius: 16,
                    child: Icon(Icons.class_, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // السطر الثاني: عدد الطلاب والأيقونات المقابلة مع تباعد منطقي
              Row(
                children: <Widget>[
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.people_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            countText,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'البادجات',
                    icon: const Icon(Icons.badge),
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: () => context.push(
                      AppRoutes.classLocation('/badges', c.id, title),
                      extra: ref0,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'كشف اليوم',
                    icon: const Icon(Icons.fact_check),
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: () => context.push(
                      AppRoutes.classLocation('/day-sheet', c.id, title),
                      extra: ref0,
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'تعديل',
                    icon: const Icon(Icons.edit),
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: () => _edit(c),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: 'حذف',
                    icon: const Icon(Icons.delete),
                    iconSize: 20,
                    color: Theme.of(context).colorScheme.error,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: () => _delete(c),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(SchoolClass? c) async {
    final AppDb db = ref.read(dbProvider);
    AcademicYear? year;
    try {
      year = await db.activeYear();
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'classes:year');
      if (!mounted) {
        return;
      }
      _snack('تعذر قراءة السنة الفعّالة: $e');
      return;
    }
    if (year == null) {
      if (!mounted) {
        return;
      }
      _snack('لا توجد سنة فعّالة — أنشئها من شاشة السنوات');
      return;
    }
    final TextEditingController grade =
        TextEditingController(text: c?.grade ?? '');
    final TextEditingController section =
        TextEditingController(text: c?.section ?? '');
    if (!mounted) {
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
    if (ok != true || !mounted) {
      return;
    }
    if (grade.text.trim().isEmpty || section.text.trim().isEmpty) {
      _snack('اكتب الصف والشعبة معاً');
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
        if (!mounted) {
          return;
        }
        if (existing != null) {
          _snack('الصف والشعبة موجودان مسبقاً');
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
      if (!mounted) {
        return;
      }
      _snack(c == null ? 'أُضيف الصف' : 'حُفظ التعديل');
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'classes:save');
      if (!mounted) {
        return;
      }
      _snack('تعذر الحفظ: $e');
    }
  }

  /// حذف صف فارغ فقط؛ الصف الذي فيه طلاب يُوجَّه لحذفهم أولاً (حماية البيانات).
  Future<void> _delete(SchoolClass c) async {
    final AppDb db = ref.read(dbProvider);
    int kids;
    try {
      kids = await db.countStudentsInClass(c.id);
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'classes:count');
      if (!mounted) {
        return;
      }
      _snack('تعذر فحص الصف: $e');
      return;
    }
    if (!mounted) {
      return;
    }
    if (kids > 0) {
      _snack('الصف فيه $kids طالباً — احذف الطلاب أو رقّهم أولاً');
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
      if (!mounted) {
        return;
      }
      _snack('حُذف الصف');
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'classes:delete');
      if (!mounted) {
        return;
      }
      _snack('تعذر الحذف: $e');
    }
  }
}
