/// إدارة الإجازات: إضافة/حذف مع نوع وسبب، تنعكس أصفر في التقارير وتلغي
/// سجلات الغياب داخل نطاق الإجازة (تلقائياً كانت أو يدوية) — وحذفها
/// يعيد الغياب الملغى ما لم تغطّه إجازة أخرى.
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../state/providers.dart';

const List<String> leaveTypeNames = <String>['مرضية', 'عرضية', 'طارئة'];

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

  Future<void> _remove(Leave l) async {
    final AppDb db = ref.read(dbProvider);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('حذف إجازة'),
        content: Text('سيُعاد احتساب أيام ${l.start} → ${l.end} غياباً إن كانت مغلقة.'),
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
    await (db.delete(db.leaves)..where((x) => x.id.equals(l.id))).go();
    await db.syncLeaveToAttendance(
      studentId: l.studentId,
      start: l.start,
      end: l.end,
      added: false,
    );
    await db.logAudit('leave_delete', 'id=${l.id}');
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('الإجازات')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
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
                          '${l.start} → ${l.end} • ${leaveTypeNames[l.type]}'
                          '${l.reason.isEmpty ? '' : ' • ${l.reason}'}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () => _remove(l),
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

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final AppDb db = ref.read(dbProvider);
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return;
    }
    final List<Student> students =
        await (db.select(db.students)..where((s) => s.yearId.equals(year.id))).get();
    if (students.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا طلاب في السنة الفعّالة بعد')),
        );
      }
      return;
    }
    Student? picked = students.first;
    DateTime start = DateTime.now();
    DateTime end = DateTime.now();
    int type = 0;
    final TextEditingController reason = TextEditingController();
    if (!context.mounted) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSt) => AlertDialog(
          title: const Text('إجازة جديدة'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DropdownButtonFormField<Student>(
                  key: ValueKey<Student?>(picked),
                  initialValue: picked,
                  items: <DropdownMenuItem<Student>>[
                    for (final Student s in students)
                      DropdownMenuItem<Student>(value: s, child: Text(s.fullName)),
                  ],
                  onChanged: (Student? s) => setSt(() => picked = s),
                  decoration: const InputDecoration(labelText: 'الطالب'),
                ),
                ListTile(
                  title: const Text('من'),
                  subtitle: Text(SchoolTime.dateKey(start)),
                  onTap: () async {
                    final DateTime? d = await showDatePicker(
                      context: context,
                      initialDate: start,
                      firstDate: DateTime(2015),
                      lastDate: DateTime(2040),
                    );
                    if (d != null) {
                      setSt(() {
                        start = d;
                        if (end.isBefore(start)) {
                          end = start;
                        }
                      });
                    }
                  },
                ),
                ListTile(
                  title: const Text('إلى'),
                  subtitle: Text(SchoolTime.dateKey(end)),
                  onTap: () async {
                    final DateTime? d = await showDatePicker(
                      context: context,
                      initialDate: end,
                      firstDate: start,
                      lastDate: DateTime(2040),
                    );
                    if (d != null) {
                      setSt(() => end = d);
                    }
                  },
                ),
                DropdownButtonFormField<int>(
                  key: ValueKey<int>(type),
                  initialValue: type,
                  items: <DropdownMenuItem<int>>[
                    for (int i = 0; i < leaveTypeNames.length; i++)
                      DropdownMenuItem<int>(value: i, child: Text(leaveTypeNames[i])),
                  ],
                  onChanged: (int? t) => setSt(() => type = t ?? 0),
                  decoration: const InputDecoration(labelText: 'النوع'),
                ),
                TextField(
                  controller: reason,
                  decoration: const InputDecoration(labelText: 'السبب (اختياري)'),
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
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    final Student? stu = picked;
    if (ok != true || stu == null || start.isAfter(end)) {
      return;
    }
    final String startKey = SchoolTime.dateKey(start);
    final String endKey = SchoolTime.dateKey(end);
    await db.into(db.leaves).insert(
          LeavesCompanion(
            yearId: Value(year.id),
            studentId: Value(stu.id),
            start: Value(startKey),
            end: Value(endKey),
            type: Value(type),
            reason: Value(reason.text.trim()),
            createdAt: Value(DateTime.now().toIso8601String()),
          ),
        );
    final int synced = await db.syncLeaveToAttendance(
      studentId: stu.id,
      start: startKey,
      end: endKey,
      added: true,
    );
    await db.logAudit('leave_add', '${stu.fullName} $startKey');
    if (context.mounted && synced > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('صُحّحت $synced سجلاً من غياب إلى إجازة')),
      );
    }
  }
}
