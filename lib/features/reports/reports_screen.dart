/// التقارير: حالة الصف لليوم، الإنذار المبكر، وملف الطالب التفصيلي.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/reports_service.dart';
import '../../state/providers.dart';
import 'student_report_screen.dart';

Color statusColor(int? status) {
  switch (status) {
    case AttendanceStatus.present:
      return Colors.green;
    case AttendanceStatus.absent:
      return Colors.red;
    case AttendanceStatus.leave:
      return Colors.amber;
    case AttendanceStatus.late:
      return Colors.orange;
    default:
      return Colors.grey;
  }
}

String statusName(int? status) {
  switch (status) {
    case AttendanceStatus.present:
      return 'حاضر';
    case AttendanceStatus.absent:
      return 'غائب';
    case AttendanceStatus.leave:
      return 'إجازة';
    case AttendanceStatus.late:
      return 'متأخر';
    default:
      return '—';
  }
}

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsState();
}

class _ReportsState extends ConsumerState<ReportsScreen> {
  int? _classId;
  String _date = SchoolTime.dateKey(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('التقارير والإنذار المبكر')),
      body: StreamBuilder<AcademicYear?>(
        stream: db.watchActiveYear(),
        builder: (BuildContext context, AsyncSnapshot<AcademicYear?> ys) {
          final AcademicYear? year = ys.data;
          if (year == null) {
            return const Center(child: Text('لا سنة فعّالة'));
          }
          return Column(
            children: <Widget>[
              _ClassPicker(
                db: db,
                yearId: year.id,
                classId: _classId,
                onChanged: (int? id) => setState(() => _classId = id),
              ),
              ListTile(
                title: const Text('تاريخ كشف الصف'),
                subtitle: Text(_date),
                trailing: const Icon(Icons.calendar_month),
                onTap: () async {
                  final DateTime? d = await showDatePicker(
                    context: context,
                    initialDate: SchoolTime.parseKey(_date),
                    firstDate: DateTime(2015),
                    lastDate: DateTime(2040),
                  );
                  if (d != null) {
                    setState(() => _date = SchoolTime.dateKey(d));
                  }
                },
              ),
              Expanded(
                child: _classId == null
                    ? _AlertsList(db: db, year: year)
                    : _ClassDayList(db: db, classId: _classId!, date: _date),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ClassPicker extends StatelessWidget {
  const _ClassPicker({
    required this.db,
    required this.yearId,
    required this.classId,
    required this.onChanged,
  });

  final AppDb db;
  final int yearId;
  final int? classId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<SchoolClass>>(
        stream: (db.select(db.schoolClasses)..where((c) => c.yearId.equals(yearId)))
            .watch(),
        builder: (BuildContext context, AsyncSnapshot<List<SchoolClass>> snap) {
          final List<SchoolClass> list = snap.data ?? <SchoolClass>[];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonFormField<int?>(
              initialValue: classId,
              decoration: const InputDecoration(
                labelText: 'الصف (اتركه فارغاً لقائمة الإنذار المبكر)',
              ),
              items: <DropdownMenuItem<int?>>[
                const DropdownMenuItem<int?>(value: null, child: Text('كل الصفوف')),
                for (final SchoolClass c in list)
                  DropdownMenuItem<int?>(
                    value: c.id,
                    child: Text('${c.grade} ـ ${c.section}'),
                  ),
              ],
              onChanged: onChanged,
            ),
          );
        },
      );
}

class _ClassDayList extends StatelessWidget {
  const _ClassDayList({required this.db, required this.classId, required this.date});

  final AppDb db;
  final int classId;
  final String date;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<(Student, int?)>>(
        future: ReportsService(db).classDayMatrix(classId, date),
        builder: (BuildContext context, AsyncSnapshot<List<(Student, int?)>> snap) {
          final List<(Student, int?)> matrix = snap.data ?? <(Student, int?)>[];
          if (matrix.isEmpty) {
            return const Center(child: Text('لا طلاب'));
          }
          return ListView.builder(
            itemCount: matrix.length,
            itemBuilder: (BuildContext context, int i) {
              final (Student s, int? st) = matrix[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: statusColor(st),
                  child: Text(statusName(st).characters.first),
                ),
                title: Text(s.fullName),
                subtitle: Text(statusName(st)),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) =>
                        StudentReportScreen(student: s),
                  ),
                ),
              );
            },
          );
        },
      );
}

class _AlertsList extends StatelessWidget {
  const _AlertsList({required this.db, required this.year});

  final AppDb db;
  final AcademicYear year;

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, String>>(
        future: db.allSettings(),
        builder: (BuildContext context, AsyncSnapshot<Map<String, String>> ss) {
          final double t1 =
              double.tryParse(ss.data?['alert_threshold_1'] ?? '10') ?? 10;
          return FutureBuilder<List<(Student, StatusTotals)>>(
            future: ReportsService(db).alerts(year.id, t1),
            builder:
                (BuildContext context, AsyncSnapshot<List<(Student, StatusTotals)>> snap) {
              final List<(Student, StatusTotals)> list =
                  snap.data ?? <(Student, StatusTotals)>[];
              if (list.isEmpty) {
                return const Center(
                  child: Text('لا طلاب تجاوزوا حد الإنذار — وضع سليم'),
                );
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (BuildContext context, int i) {
                  final (Student s, StatusTotals t) = list[i];
                  return ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Colors.red,
                      child: Icon(Icons.warning_amber, color: Colors.white),
                    ),
                    title: Text(s.fullName),
                    subtitle: Text(
                      'غياب ${t.absent} من ${t.recorded} '
                      '(${(t.absent * 100 / t.recorded).toStringAsFixed(1)}%)',
                    ),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            StudentReportScreen(student: s),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      );
}
