/// كشف اليوم لصف: حالة كل طالب ملوّنة + تصحيح يدوي + إقفال/إعادة فتح.
///
/// يكمل دورة العمل اليومية: بعد المسح (أو بدله) يرى المعلم من سُجّل ومن تبقّى،
/// ويصحّح أي حالة يدوياً (حاضر/متأخر/إجازة/غائب/إلغاء التسجيل).
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/attendance_labels.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../state/providers.dart';

enum _Filter { all, missing }

class DaySheetScreen extends ConsumerStatefulWidget {
  const DaySheetScreen({
    super.key,
    required this.classId,
    required this.date,
    required this.title,
  });

  final int classId;
  final String date;
  final String title;

  @override
  ConsumerState<DaySheetScreen> createState() => _DaySheetState();
}

class _DaySheetState extends ConsumerState<DaySheetScreen> {
  late final String _date;
  late final Stream<List<Student>> _students;
  late final Stream<List<AttendanceRow>> _rows;
  late final Stream<Session?> _session;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _date = widget.date.isEmpty ? SchoolTime.dateKey(DateTime.now()) : widget.date;
    final AppDb db = ref.read(dbProvider);
    _students = (db.select(db.students)
          ..where((s) => s.classId.equals(widget.classId))
          ..orderBy(<OrderClauseGenerator<Students>>[
            (Students s) => OrderingTerm.asc(s.fullName),
          ]))
        .watch();
    _rows = (db.select(db.attendanceRows)
          ..where(
            (a) => a.classId.equals(widget.classId) & a.date.equals(_date),
          ))
        .watch();
    _session = db.watchSession(widget.classId, _date);
  }

  Future<void> _setStatus(Student s, int? status) async {
    final AppDb db = ref.read(dbProvider);
    final Session? ses = await db.sessionOf(widget.classId, _date);
    if (status == null) {
      await (db.delete(db.attendanceRows)
            ..where(
              (a) => a.studentId.equals(s.id) & a.date.equals(_date),
            ))
          .go();
    } else {
      await db.upsertAttendance(
        yearId: s.yearId,
        classId: s.classId,
        studentId: s.id,
        date: _date,
        status: status,
        source: AttendanceSource.manual,
        sessionId: ses?.id,
      );
    }
    await db.logAudit('day_sheet_set', '${s.fullName} => $status');
  }

  Future<void> _pickStatus(Student s, int? current) async {
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(s.fullName),
        children: <Widget>[
          for (final int st in <int>[
            AttendanceStatus.present,
            AttendanceStatus.late,
            AttendanceStatus.leave,
            AttendanceStatus.absent,
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, st),
              child: Row(
                children: <Widget>[
                  Icon(Icons.circle, color: statusColor(st), size: 14),
                  const SizedBox(width: 8),
                  Text(statusName(st)),
                  if (st == current) const Spacer(),
                  if (st == current) const Icon(Icons.check, size: 16),
                ],
              ),
            ),
          if (current != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, -1),
              child: const Text('إلغاء التسجيل لهذا اليوم'),
            ),
        ],
      ),
    );
    if (picked == null) {
      return;
    }
    await _setStatus(s, picked == -1 ? null : picked);
  }

  Future<bool> _confirmClose(int missing) async {
    final AppDb db = ref.read(dbProvider);
    final Map<String, String> s = await db.effectiveSettings();
    final Set<int> weekdays = <int>{
      for (final String w in (s['work_weekdays'] ?? '7,1,2,3,4').split(','))
        int.tryParse(w) ?? 0,
    };
    final Set<String> holidays = <String>{
      for (final Holiday h in await db.select(db.holidays).get()) h.date,
    };
    final bool schoolDay = SchoolTime.isSchoolDay(
      SchoolTime.parseKey(_date),
      workWeekdays: weekdays,
      holidayKeys: holidays,
    );
    if (!mounted) {
      return false;
    }
    return await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('إقفال اليوم'),
            content: Text(
              '${schoolDay ? '' : 'تنبيه: هذا اليوم ليس يوم دوام حسب الإعدادات!\n'}'
              'سيُسجل $missing طالباً كغائبين (أو بإجازة إن وجدت). '
              'يمكن إعادة الفتح لاحقاً لتصحيح الأخطاء.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('تراجع'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('أقفل اليوم'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _toggleClose(Session ses, int missing) async {
    final AppDb db = ref.read(dbProvider);
    if (ses.closedAt == null) {
      final bool ok = await _confirmClose(missing);
      if (!ok) {
        return;
      }
      final int n = await db.closeSession(ses.id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('أُقفل اليوم وولّد $n سجلاً')));
      }
    } else {
      await db.reopenSession(ses.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('أُعيد فتح اليوم؛ حُذفت السجلات التلقائية')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('كشف ${widget.title} — $_date'),
        actions: <Widget>[
          IconButton(
            tooltip: 'شاشة المسح',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => context.push(
              '/scan?class=${widget.classId}'
              '&title=${Uri.encodeComponent(widget.title)}',
            ),
          ),
        ],
      ),
      body: StreamBuilder<Session?>(
        stream: _session,
        builder: (BuildContext context, AsyncSnapshot<Session?> ss) {
          final Session? ses = ss.data;
          return Column(
            children: <Widget>[
              _SummaryBar(
                sessionStream: _session,
                studentsStream: _students,
                rowsStream: _rows,
                onToggleClose: ses == null ? null : () => _missingCount(db).then(
                      (int m) => _toggleClose(ses, m),
                    ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SegmentedButton<_Filter>(
                  segments: const <ButtonSegment<_Filter>>[
                    ButtonSegment<_Filter>(
                      value: _Filter.all,
                      label: Text('الكل'),
                    ),
                    ButtonSegment<_Filter>(
                      value: _Filter.missing,
                      label: Text('غير المسجلين'),
                    ),
                  ],
                  selected: <_Filter>{_filter},
                  onSelectionChanged: (Set<_Filter> v) =>
                      setState(() => _filter = v.first),
                ),
              ),
              Expanded(
                child: StreamBuilder<List<Student>>(
                  stream: _students,
                  builder: (
                    BuildContext context,
                    AsyncSnapshot<List<Student>> snap,
                  ) {
                    final List<Student> roster = snap.data ?? <Student>[];
                    return StreamBuilder<List<AttendanceRow>>(
                      stream: _rows,
                      builder: (
                        BuildContext context,
                        AsyncSnapshot<List<AttendanceRow>> rs,
                      ) {
                        final Map<int, int> byId = <int, int>{
                          for (final AttendanceRow r
                              in rs.data ?? <AttendanceRow>[])
                            r.studentId: r.status,
                        };
                        final List<Student> shown = _filter == _Filter.missing
                            ? roster
                                .where((Student s) => !byId.containsKey(s.id))
                                .toList()
                            : roster;
                        if (shown.isEmpty) {
                          return const Center(
                            child: Text('لا طلاب في هذا النطاق'),
                          );
                        }
                        return ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (BuildContext context, int i) {
                            final Student s = shown[i];
                            final int? st = byId[s.id];
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: statusColor(st),
                                child: Text(
                                  statusLetter(st),
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              title: Text(s.fullName),
                              subtitle: Text(
                                '${statusHint(st)} • رقم ${s.seq}',
                              ),
                              trailing: const Icon(Icons.edit),
                              onTap: () => _pickStatus(s, st),
                              onLongPress: () =>
                                  context.push('/student/${s.id}'),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<int> _missingCount(AppDb db) async {
    final List<Student> roster = await (db.select(db.students)
          ..where((s) => s.classId.equals(widget.classId)))
        .get();
    final int recorded = await db.recordedCount(widget.classId, _date);
    return roster.length - recorded;
  }
}

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({
    required this.sessionStream,
    required this.studentsStream,
    required this.rowsStream,
    required this.onToggleClose,
  });

  final Stream<Session?> sessionStream;
  final Stream<List<Student>> studentsStream;
  final Stream<List<AttendanceRow>> rowsStream;
  final VoidCallback? onToggleClose;

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Student>>(
        stream: studentsStream,
        builder: (BuildContext context, AsyncSnapshot<List<Student>> snap) {
          final int total = (snap.data ?? <Student>[]).length;
          return StreamBuilder<List<AttendanceRow>>(
            stream: rowsStream,
            builder: (
              BuildContext context,
              AsyncSnapshot<List<AttendanceRow>> rs,
            ) {
              final List<AttendanceRow> rows = rs.data ?? <AttendanceRow>[];
              final int recorded = rows
                  .where(
                    (AttendanceRow r) =>
                        r.status == AttendanceStatus.present ||
                        r.status == AttendanceStatus.late ||
                        r.status == AttendanceStatus.leave,
                  )
                  .length;
              return StreamBuilder<Session?>(
                stream: sessionStream,
                builder: (BuildContext context, AsyncSnapshot<Session?> ss) {
                  final Session? ses = ss.data;
                  final bool closed = ses?.closedAt != null;
                  return Card(
                    margin: const EdgeInsets.all(8),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: <Widget>[
                          Text('مسجل: $recorded / $total'),
                          Text(closed ? 'مقفلة' : 'مفتوحة'),
                          FilledButton.icon(
                            onPressed: onToggleClose,
                            icon: Icon(closed ? Icons.lock_open : Icons.lock),
                            label: Text(closed ? 'إعادة فتح' : 'إقفال اليوم'),
                          ),
                        ],
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
