/// التقارير: حالة الصف لليوم، الإنذار المبكر بعتبتين، وملف الطالب التفصيلي.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/attendance_labels.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/reports_service.dart';
import '../../state/providers.dart';

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
                  if (d != null && mounted) {
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
              key: ValueKey<int?>(classId),
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

/// كشف صف ليوم: مستقبل يُحسب مرة لكل تغيّر مدخلات (لا في كل بناء).
class _ClassDayList extends StatefulWidget {
  const _ClassDayList({required this.db, required this.classId, required this.date});

  final AppDb db;
  final int classId;
  final String date;

  @override
  State<_ClassDayList> createState() => _ClassDayListState();
}

class _ClassDayListState extends State<_ClassDayList> {
  late Future<List<(Student, int?)>> _future;

  @override
  void initState() {
    super.initState();
    _future = ReportsService(widget.db).classDayMatrix(widget.classId, widget.date);
  }

  @override
  void didUpdateWidget(_ClassDayList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.classId != widget.classId || oldWidget.date != widget.date) {
      _future =
          ReportsService(widget.db).classDayMatrix(widget.classId, widget.date);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<(Student, int?)>>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<List<(Student, int?)>> snap) {
          final List<(Student, int?)> matrix = snap.data ?? <(Student, int?)>[];
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (matrix.isEmpty) {
            return const Center(child: Text('لا طلاب في هذا الصف'));
          }
          return ListView.builder(
            itemCount: matrix.length,
            itemBuilder: (BuildContext context, int i) {
              final (Student s, int? st) = matrix[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: statusColor(st),
                  child: Text(
                    statusLetter(st),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                title: Text(s.fullName),
                subtitle: Text(statusHint(st)),
                onTap: () => context.push('/student/${s.id}'),
              );
            },
          );
        },
      );
}

/// الإنذار المبكر بعتبتين: تحذير (الأولى) وخطر (الثانية).
class _AlertsList extends StatefulWidget {
  const _AlertsList({required this.db, required this.year});

  final AppDb db;
  final AcademicYear year;

  @override
  State<_AlertsList> createState() => _AlertsListState();
}

class _AlertsListState extends State<_AlertsList> {
  late Future<Map<String, String>> _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.db.effectiveSettings();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, String>>(
        future: _settings,
        builder: (BuildContext context, AsyncSnapshot<Map<String, String>> ss) {
          final double t1 =
              double.tryParse(ss.data?['alert_threshold_1'] ?? '10') ?? 10;
          final double t2 =
              double.tryParse(ss.data?['alert_threshold_2'] ?? '15') ?? 15;
          return FutureBuilder<List<(Student, StatusTotals)>>(
            future: ReportsService(widget.db).alerts(widget.year.id, t1),
            builder: (
              BuildContext context,
              AsyncSnapshot<List<(Student, StatusTotals)>> snap,
            ) {
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
                  final double pct = t.recorded == 0
                      ? 0
                      : t.absent * 100 / t.recorded;
                  final bool danger = pct >= t2;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: danger ? Colors.red : Colors.orange,
                      child: const Icon(Icons.warning_amber, color: Colors.white),
                    ),
                    title: Text(s.fullName),
                    subtitle: Text(
                      'غياب ${t.absent} من ${t.recorded} '
                      '(${pct.toStringAsFixed(1)}%)'
                      '${danger ? ' — تجاوز الحد الثاني' : ' — تجاوز الحد الأول'}',
                    ),
                    onTap: () => context.push('/student/${s.id}'),
                  );
                },
              );
            },
          );
        },
      );
}
