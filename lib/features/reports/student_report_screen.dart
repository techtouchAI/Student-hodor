/// ملف الطالب التفصيلي: مجاميع، شبكة شهر ملوّنة، إجازات، مسيرة سنوات.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/reports_service.dart';
import '../../state/providers.dart';
import 'reports_screen.dart';

class StudentReportScreen extends ConsumerStatefulWidget {
  const StudentReportScreen({super.key, required this.student});

  final Student student;

  @override
  ConsumerState<StudentReportScreen> createState() => _StudentReportState();
}

class _StudentReportState extends ConsumerState<StudentReportScreen> {
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _year = now.year;
    _month = now.month;
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    final Student s = widget.student;
    return Scaffold(
      appBar: AppBar(title: Text(s.fullName)),
      body: StreamBuilder<AcademicYear?>(
        stream: db.watchActiveYear(),
        builder: (BuildContext context, AsyncSnapshot<AcademicYear?> ys) {
          final AcademicYear? year = ys.data;
          if (year == null) {
            return const Center(child: Text('لا سنة فعّالة'));
          }
          final ReportsService reports = ReportsService(db);
          return FutureBuilder<Map<String, String>>(
            future: db.allSettings(),
            builder: (BuildContext context, AsyncSnapshot<Map<String, String>> ss) {
              final Set<int> weekdays = <int>{
                for (final String w
                    in (ss.data?['work_weekdays'] ?? '7,1,2,3,4').split(','))
                  int.tryParse(w) ?? 0,
              };
              return FutureBuilder<List<Holiday>>(
                future: db.select(db.holidays).get(),
                builder: (BuildContext context, AsyncSnapshot<List<Holiday>> hs) {
                  final Set<String> holidays = <String>{
                    for (final Holiday h in hs.data ?? <Holiday>[]) h.date,
                  };
                  return ListView(
                    padding: const EdgeInsets.all(12),
                    children: <Widget>[
                      _TotalsCard(reports: reports, student: s, yearId: year.id),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          IconButton(
                            icon: const Icon(Icons.chevron_right),
                            onPressed: () => setState(() {
                              _month--;
                              if (_month < 1) {
                                _month = 12;
                                _year--;
                              }
                            }),
                          ),
                          Expanded(
                            child: Center(
                              child: Text(
                                '${SchoolTime.monthNames[_month - 1]} $_year',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_left),
                            onPressed: () => setState(() {
                              _month++;
                              if (_month > 12) {
                                _month = 1;
                                _year++;
                              }
                            }),
                          ),
                        ],
                      ),
                      FutureBuilder<List<DayCell>>(
                        future: reports.monthCells(
                          studentId: s.id,
                          yearId: year.id,
                          year: _year,
                          month: _month,
                          workWeekdays: weekdays,
                          holidayKeys: holidays,
                        ),
                        builder: (BuildContext context,
                            AsyncSnapshot<List<DayCell>> snap) {
                          final List<DayCell> cells = snap.data ?? <DayCell>[];
                          return Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: <Widget>[
                              for (final DayCell c in cells)
                                Tooltip(
                                  message:
                                      '${c.dateKey}: ${statusName(c.status)}',
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: c.isSchoolDay
                                          ? statusColor(c.status)
                                          : Colors.grey.shade300,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '${SchoolTime.parseKey(c.dateKey).day}',
                                      style: const TextStyle(color: Colors.white),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      _LeavesCard(db: db, student: s),
                      const SizedBox(height: 12),
                      _JourneyCard(reports: reports, student: s),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({
    required this.reports,
    required this.student,
    required this.yearId,
  });

  final ReportsService reports;
  final Student student;
  final int yearId;

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<StatusTotals>(
        future: reports.totalsForStudent(student.id, yearId),
        builder: (BuildContext context, AsyncSnapshot<StatusTotals> snap) {
          final StatusTotals t = snap.data ?? const StatusTotals();
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: <Widget>[
                  _Stat('حضور', t.present, Colors.green),
                  _Stat('غياب', t.absent, Colors.red),
                  _Stat('إجازة', t.leave, Colors.amber),
                  _Stat('متأخر', t.late, Colors.orange),
                  _Stat('النسبة', t.ratePct.round(), Colors.teal),
                ],
              ),
            ),
          );
        },
      );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          Text('$value', style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold)),
          Text(label),
        ],
      );
}

class _LeavesCard extends StatelessWidget {
  const _LeavesCard({required this.db, required this.student});

  final AppDb db;
  final Student student;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Leave>>(
        future: (db.select(db.leaves)
              ..where((l) => l.studentId.equals(student.id)))
            .get(),
        builder: (BuildContext context, AsyncSnapshot<List<Leave>> snap) {
          final List<Leave> leaves = snap.data ?? <Leave>[];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('الإجازات', style: TextStyle(fontWeight: FontWeight.bold)),
                  if (leaves.isEmpty) const Text('لا إجازات'),
                  for (final Leave l in leaves)
                    Text('${l.start} → ${l.end} (${l.reason})'),
                ],
              ),
            ),
          );
        },
      );
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({required this.reports, required this.student});

  final ReportsService reports;
  final Student student;

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<(AcademicYear, StatusTotals)>>(
        future: reports.studentJourney(student),
        builder: (BuildContext context,
            AsyncSnapshot<List<(AcademicYear, StatusTotals)>> snap) {
          final List<(AcademicYear, StatusTotals)> journey =
              snap.data ?? <(AcademicYear, StatusTotals)>[];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'مسيرة الطالب عبر السنوات',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (journey.isEmpty) const Text('لا سجلات سابقة'),
                  for (final (AcademicYear y, StatusTotals t) in journey)
                    Text(
                      '${y.name}: حضور ${t.present + t.late}، غياب ${t.absent}، '
                      'إجازة ${t.leave} — نسبة ${t.ratePct.toStringAsFixed(1)}%',
                    ),
                ],
              ),
            ),
          );
        },
      );
}
