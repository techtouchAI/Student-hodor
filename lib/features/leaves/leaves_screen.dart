/// إدارة الإجازات: إضافة/حذف مع نوع وسبب، تنعكس أصفر في التقارير.
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../state/providers.dart';

const List<String> leaveTypeNames = <String>['مرضية', 'عرضية', 'طارئة'];

class LeavesScreen extends ConsumerWidget {
  const LeavesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          return StreamBuilder<List<Leave>>(
            stream: (db.select(db.leaves)
                  ..where((l) => l.yearId.equals(year.id))
                  ..orderBy(<OrderClauseGenerator<Leaves>>[
                    (Leaves l) => OrderingTerm.desc(l.start),
                  ]))
                .watch(),
            builder: (BuildContext context, AsyncSnapshot<List<Leave>> snap) {
              final List<Leave> leaves = snap.data ?? <Leave>[];
              if (leaves.isEmpty) {
                return const Center(child: Text('لا إجازات مسجلة'));
              }
              return ListView.builder(
                itemCount: leaves.length,
                itemBuilder: (BuildContext context, int i) {
                  final Leave l = leaves[i];
                  return FutureBuilder<Student?>(
                    future: (db.select(db.students)
                          ..where((s) => s.id.equals(l.studentId)))
                        .getSingleOrNull(),
                    builder: (BuildContext context, AsyncSnapshot<Student?> ss) =>
                        ListTile(
                      title: Text(ss.data?.fullName ?? '…'),
                      subtitle: Text(
                        '${l.start} → ${l.end} • ${leaveTypeNames[l.type]}'
                        '${l.reason.isEmpty ? '' : ' • ${l.reason}'}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () async {
                          await (db.delete(db.leaves)
                                ..where((x) => x.id.equals(l.id)))
                              .go();
                          await db.logAudit('leave_delete', 'id=${l.id}');
                        },
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

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final AppDb db = ref.read(dbProvider);
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return;
    }
    final List<Student> students =
        await (db.select(db.students)..where((s) => s.yearId.equals(year.id))).get();
    if (students.isEmpty) {
      return;
    }
    Student? picked = students.first;
    DateTime start = DateTime.now();
    DateTime end = DateTime.now();
    int type = 0;
    final TextEditingController reason = TextEditingController();
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
    await db.into(db.leaves).insert(
          LeavesCompanion(
            yearId: Value(year.id),
            studentId: Value(stu.id),
            start: Value(SchoolTime.dateKey(start)),
            end: Value(SchoolTime.dateKey(end)),
            type: Value(type),
            reason: Value(reason.text.trim()),
            createdAt: Value(DateTime.now().toIso8601String()),
          ),
        );
    await db.logAudit('leave_add', '${stu.fullName} ${SchoolTime.dateKey(start)}');
  }
}
