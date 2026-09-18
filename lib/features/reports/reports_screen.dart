/// التقارير: حالة الصف لليوم، الإنذار المبكر بعتبتين، وملف الطالب التفصيلي.
library;

import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/attendance_labels.dart';
import '../../core/error_guard.dart';
import '../../core/late_time.dart';
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
  Widget build(BuildContext context) => StreamGuard<List<SchoolClass>>(
        stream: (db.select(db.schoolClasses)
              ..where((c) => c.yearId.equals(yearId)))
            .watch(),
        loading: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: LinearProgressIndicator(minHeight: 3),
        ),
        builder: (BuildContext context, List<SchoolClass> list) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButtonFormField<int?>(
              key: ValueKey<int?>(classId),
              initialValue: classId,
              // تسمية قصيرة + نص مساعدة يلتفّ: التسمية الطويلة تُقتطع ولا
              // تظهر كاملة داخل الحقل.
              decoration: const InputDecoration(
                labelText: 'الصف',
                helperText: '«كل الصفوف» تعرض قائمة الإنذار المبكر',
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
  /// (مصفوفة اليوم، بداية الدوام من الإعدادات) — الثانية لحساب مدة التأخر
  /// المعروضة تحت اسم كل متأخر، وتُجلب في المستقبل نفسه لا في كل بناء.
  late Future<(List<(Student, AttendanceRow?)>, String)> _future;

  Future<(List<(Student, AttendanceRow?)>, String)> _load() async {
    final List<(Student, AttendanceRow?)> matrix =
        await ReportsService(widget.db).classDayMatrix(widget.classId, widget.date);
    final Map<String, String> settings = await widget.db.effectiveSettings();
    return (matrix, settings['day_start'] ?? '08:00');
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(_ClassDayList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.classId != widget.classId || oldWidget.date != widget.date) {
      _future = _load();
    }
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<(List<(Student, AttendanceRow?)>, String)>(
        future: _future,
        builder: (
          BuildContext context,
          AsyncSnapshot<(List<(Student, AttendanceRow?)>, String)> snap,
        ) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          // لا تعبير سجل يبدأ بقائمة منمّطة: المحلل يلتبس فيه — فكّ صريح.
          final (List<(Student, AttendanceRow?)>, String)? data = snap.data;
          final List<(Student, AttendanceRow?)> matrix = data?.$1 ??
              const <(Student, AttendanceRow?)>[];
          final String dayStart = data?.$2 ?? '08:00';
          if (matrix.isEmpty) {
            return const Center(child: Text('لا طلاب في هذا الصف'));
          }
          return ListView.builder(
            itemCount: matrix.length,
            itemBuilder: (BuildContext context, int i) {
              final (Student s, AttendanceRow? row) = matrix[i];
              // «فقرة التأخير»: المتأخر يظهر وقته الفعلي ومدته تحت اسمه.
              final String line = row != null &&
                      row.status == AttendanceStatus.late
                  ? lateInfoLabel(
                      arrivalTime: row.arrivalTime,
                      dayStart: dayStart,
                    )
                  : statusHint(row?.status);
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: statusColor(row?.status),
                  child: Text(
                    statusLetter(row?.status),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                title: Text(s.fullName),
                subtitle: Text(line),
                onTap: () => context.push('/student/${s.id}'),
              );
            },
          );
        },
      );
}

/// الإنذار المبكر بعتبتين **أيام غياب** من الإعدادات: تحذير (الأولى)
/// وخطر (الثانية). القائمة حيّة: أي حفظ في الإعدادات أو أي تسجيل حضور
/// يعيد الحساب فوراً — لا عتبات قديمة بعد العودة من الإعدادات.
/// النسبة في السطر سياقٌ إضافي فقط؛ الترشيح والدرجة بعدد الأيام.
class _AlertsList extends StatefulWidget {
  const _AlertsList({required this.db, required this.year});

  final AppDb db;
  final AcademicYear year;

  @override
  State<_AlertsList> createState() => _AlertsListState();
}

class _AlertsListState extends State<_AlertsList> {
  double _t1 = 10;
  double _t2 = 15;
  StreamSubscription<void>? _settingsSub;
  StreamSubscription<void>? _attendanceSub;

  @override
  void initState() {
    super.initState();
    final AppDb db = widget.db;
    _settingsSub = db.select(db.settings).watch().listen(_onSettings);
    // عدّاد خفيف (لا كل الصفوف): أي تغيير حضور يعيد حساب القائمة.
    _attendanceSub = db
        .customSelect(
          'SELECT COUNT(*) AS c FROM attendance_rows',
          readsFrom: {db.attendanceRows},
        )
        .watch()
        .listen((_) => _reload());
  }

  /// عتبات جديدة محفوظة في الإعدادات ⇒ تُعتمد فوراً وتُعاد القائمة.
  void _onSettings(List<Setting> rows) {
    final Map<String, String> all = <String, String>{
      ...AppDb.settingDefaults,
      for (final Setting s in rows) s.key: s.value,
    };
    _t1 = double.tryParse(all['alert_threshold_1'] ?? '10') ?? 10;
    _t2 = double.tryParse(all['alert_threshold_2'] ?? '15') ?? 15;
    _reload();
  }

  void _reload() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    unawaited(_settingsSub?.cancel());
    unawaited(_attendanceSub?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async => _reload();

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<(Student, StatusTotals)>>(
        future: ReportsService(widget.db).alerts(widget.year.id, _t1),
        builder: (
          BuildContext context,
          AsyncSnapshot<List<(Student, StatusTotals)>> snap,
        ) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final List<(Student, StatusTotals)> list =
              snap.data ?? <(Student, StatusTotals)>[];
          if (list.isEmpty) {
            return const Center(
              child: Text('لا طلاب تجاوزوا حد الإنذار — وضع سليم'),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (BuildContext context, int i) {
                final (Student s, StatusTotals t) = list[i];
                final double pct = t.recorded == 0
                    ? 0
                    : t.absent * 100 / t.recorded;
                final bool danger = t.absent >= _t2;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: danger ? Colors.red : Colors.orange,
                    child:
                        const Icon(Icons.warning_amber, color: Colors.white),
                  ),
                  title: Text(s.fullName),
                  subtitle: Text(
                    'غياب ${t.absent} من ${t.recorded} يوم '
                    '(${pct.toStringAsFixed(1)}%)'
                    '${danger ? ' — تجاوز الحد الثاني' : ' — تجاوز الحد الأول'}',
                  ),
                  onTap: () => context.push('/student/${s.id}'),
                );
              },
            ),
          );
        },
      );
}
