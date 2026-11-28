/// إدارة الإجازات: إضافة/تعديل/حذف مع نوع وسبب، تنعكس أصفر في التقارير
/// وتلغي سجلات الغياب داخل نطاق الإجازة (تلقائياً كانت أو يدوية) — وحذفها
/// أو تضييقها يعيد الغياب الملغى ما لم تغطّه إجازة أخرى. وإن نزل الطالب
/// بالإجازة تحت حد الفصل أُزيل تنبيهه (راجع `LeavesService`).
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lesson.dart';
import '../../data/db.dart';
import '../../data/leaves_service.dart';
import '../../state/providers.dart';
import 'leave_editor_dialog.dart';

export '../../data/leaves_service.dart' show leaveTypeNames;

class LeavesScreen extends ConsumerStatefulWidget {
  const LeavesScreen({super.key});

  @override
  ConsumerState<LeavesScreen> createState() => _LeavesState();
}

class _LeavesState extends ConsumerState<LeavesScreen> {
  late final Stream<List<Leave>> _leaves;
  late final Stream<List<Student>> _students;

  @override
  void initState() {
    super.initState();
    final AppDb db = ref.read(dbProvider);
    _leaves = (db.select(db.leaves)
          ..orderBy(<OrderClauseGenerator<Leaves>>[
            (Leaves l) => OrderingTerm.desc(l.start),
          ]))
        .watch();
    _students = db.select(db.students).watch();
  }

  /// وصف نطاق الحصص كما يظهر في القائمة.
  static String _scopeLabel(Leave l) =>
      ' • ${leaveScopeLabel(fromSlot: l.fromSlot, toSlot: l.toSlot)}';

  /// اسم نوع الإجازة مع حماية من قيمة خارج المدى (نسخة قديمة/تالفة).
  static String _typeLabel(int type) =>
      type >= 0 && type < leaveTypeNames.length ? leaveTypeNames[type] : '—';

  Future<void> _remove(Leave l) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('حذف إجازة'),
        content: Text(
          'سيُعاد احتساب حصص ${l.start} → ${l.end} غياباً إن كانت مغلقة — '
          'داخل نطاق الإجازة وحده.',
        ),
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
    await LeavesService(ref.read(dbProvider)).delete(l);
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('الإجازات')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('إجازة'),
      ),
      body: StreamBuilder<AcademicYear?>(
        stream: db.watchActiveYear(),
        builder: (BuildContext context, AsyncSnapshot<AcademicYear?> ys) {
          final AcademicYear? year = ys.data;
          if (year == null) {
            return const Center(child: Text('لا سنة فعّالة'));
          }
          return StreamBuilder<List<Student>>(
            stream: _students,
            builder: (
              BuildContext context,
              AsyncSnapshot<List<Student>> ns,
            ) {
              final Map<int, String> names = <int, String>{
                for (final Student s in ns.data ?? <Student>[]) s.id: s.fullName,
              };
              return StreamBuilder<List<Leave>>(
                stream: _leaves,
                builder: (
                  BuildContext context,
                  AsyncSnapshot<List<Leave>> snap,
                ) {
                  final List<Leave> leaves = <Leave>[
                    for (final Leave l in snap.data ?? <Leave>[])
                      if (l.yearId == year.id) l,
                  ];
                  if (leaves.isEmpty) {
                    return const Center(child: Text('لا إجازات مسجلة'));
                  }
                  return ListView.builder(
                    itemCount: leaves.length,
                    itemBuilder: (BuildContext context, int i) {
                      final Leave l = leaves[i];
                      return ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.beach_access),
                        ),
                        title: Text(names[l.studentId] ?? 'طالب محذوف'),
                        subtitle: Text(
                          '${l.start} → ${l.end} • ${_typeLabel(l.type)}'
                          '${_scopeLabel(l)}'
                          '${l.reason.isEmpty ? '' : ' • ${l.reason}'}',
                        ),
                        onTap: () => _edit(l),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              tooltip: 'تعديل',
                              icon: const Icon(Icons.edit),
                              onPressed: () => _edit(l),
                            ),
                            IconButton(
                              tooltip: 'حذف',
                              icon: const Icon(Icons.delete),
                              onPressed: () => _remove(l),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  /// طلاب سنة الإجازة وحصص الجدول — مدخلات حوار التحرير.
  Future<(List<Student>, List<LessonWindow>)> _editorInputs(int yearId) async {
    final AppDb db = ref.read(dbProvider);
    final List<Student> students = await (db.select(db.students)
          ..where((s) => s.yearId.equals(yearId)))
        .get();
    return (students, await db.lessonWindows());
  }

  Future<void> _add() async {
    final AcademicYear? year = await ref.read(dbProvider).activeYear();
    if (year == null) {
      return;
    }
    final (List<Student> students, List<LessonWindow> lessons) =
        await _editorInputs(year.id);
    if (!mounted) {
      return;
    }
    if (students.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا طلاب في السنة الفعّالة بعد')),
      );
      return;
    }
    final LeaveDraft? draft = await showLeaveEditor(
      context,
      students: students,
      lessons: lessons,
    );
    if (draft == null) {
      return;
    }
    final LeaveChange change = await LeavesService(ref.read(dbProvider))
        .add(yearId: year.id, draft: draft);
    _report(change, edited: false);
  }

  Future<void> _edit(Leave l) async {
    final (List<Student> students, List<LessonWindow> lessons) =
        await _editorInputs(l.yearId);
    if (!mounted) {
      return;
    }
    final LeaveDraft? draft = await showLeaveEditor(
      context,
      students: students,
      lessons: lessons,
      initial: LeaveDraft.of(l),
    );
    if (draft == null) {
      return;
    }
    try {
      final LeaveChange change =
          await LeavesService(ref.read(dbProvider)).update(l, draft);
      _report(change, edited: true);
    } on LeaveNotFoundException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الإجازة لم تعد موجودة')),
        );
      }
    }
  }

  /// رسالة النتيجة: الحصص المصحّحة وتنبيهات حد الفصل المُزالة.
  void _report(LeaveChange change, {required bool edited}) {
    if (!mounted) {
      return;
    }
    final List<String> parts = <String>[
      if (edited) 'عُدّلت الإجازة',
      if (change.syncedLessons > 0)
        edited
            ? 'أُعيد احتساب ${change.syncedLessons} حصة'
            : 'صُحّحت ${change.syncedLessons} حصة من غياب إلى إجازة',
      if (change.dismissedAlerts.isNotEmpty)
        'أُزيل تنبيه حد الفصل (${change.dismissedAlerts.length})',
    ];
    if (parts.isEmpty) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(parts.join(' • '))),
    );
  }
}
