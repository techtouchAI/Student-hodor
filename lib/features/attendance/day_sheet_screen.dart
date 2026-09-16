/// كشف اليوم لصف: حالة كل طالب ملوّنة + تصحيح يدوي + إقفال/إعادة فتح.
///
/// يكمل دورة العمل اليومية: بعد المسح (أو بدله) يرى المعلم من سُجّل ومن تبقّى،
/// ويصحّح أي حالة يدوياً (حاضر/متأخر/إجازة/غائب/إلغاء التسجيل).
///
/// الصف والتاريخ يُحلّان من قاعدة البيانات ([AppDb.resolveClassRef]) فلا تعتمد
/// الشاشة على سلامة معاملة الرابط، وكل تدفق له حالة خطأ ظاهرة (لا بياض صامت).
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/attendance_labels.dart';
import '../../core/error_guard.dart';
import '../../core/nav.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../state/providers.dart';

enum _Filter { all, missing }

class DaySheetScreen extends ConsumerStatefulWidget {
  const DaySheetScreen({super.key, required this.classRef, this.date = ''});

  final ClassRef classRef;
  final String date;

  @override
  ConsumerState<DaySheetScreen> createState() => _DaySheetState();
}

class _DaySheetState extends ConsumerState<DaySheetScreen> {
  late String _date;
  ClassRef? _class;
  Stream<List<Student>>? _students;
  Stream<List<AttendanceRow>>? _rows;
  Stream<Session?>? _session;
  bool _resolving = true;
  String? _resolveError;
  List<SchoolClass> _options = <SchoolClass>[];
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _date = widget.date.trim().isEmpty
        ? SchoolTime.dateKey(DateTime.now())
        : widget.date.trim();
    _start(widget.classRef);
  }

  @override
  void didUpdateWidget(DaySheetScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.classRef.id != widget.classRef.id || oldWidget.date != widget.date) {
      _date = widget.date.trim().isEmpty
          ? SchoolTime.dateKey(DateTime.now())
          : widget.date.trim();
      _start(widget.classRef);
    }
  }

  Future<void> _start(ClassRef requested) async {
    setState(() {
      _resolving = true;
      _resolveError = null;
    });
    try {
      final AppDb db = ref.read(dbProvider);
      final (int count, ClassRef? resolved) =
          await db.resolveClassRef(requested);
      if (!mounted) {
        return;
      }
      if (resolved == null) {
        _options = await _classesOfActiveYear(db);
        if (!mounted) {
          return;
        }
        setState(() {
          _class = null;
          _students = null;
          _rows = null;
          _session = null;
          _resolving = false;
          _resolveError = count == 0
              ? 'لا توجد صفوف في السنة الفعّالة — أضف صفاً من شاشة الصفوف.'
              : null;
        });
        return;
      }
      setState(() {
        _class = resolved;
        _students = (db.select(db.students)
              ..where((s) => s.classId.equals(resolved.id))
              ..orderBy(<OrderClauseGenerator<Students>>[
                (Students s) => OrderingTerm.asc(s.fullName),
              ]))
            .watch();
        _rows = (db.select(db.attendanceRows)
              ..where(
                (a) => a.classId.equals(resolved.id) & a.date.equals(_date),
              ))
            .watch();
        _session = db.watchSession(resolved.id, _date);
        _resolving = false;
      });
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'daySheet:resolve');
      if (mounted) {
        setState(() {
          _resolving = false;
          _resolveError = '$e';
        });
      }
    }
  }

  Future<List<SchoolClass>> _classesOfActiveYear(AppDb db) async {
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return <SchoolClass>[];
    }
    return (db.select(db.schoolClasses)
          ..where((c) => c.yearId.equals(year.id))
          ..orderBy(<OrderClauseGenerator<SchoolClasses>>[
            (SchoolClasses c) => OrderingTerm.asc(c.grade),
            (SchoolClasses c) => OrderingTerm.asc(c.section),
          ]))
        .get();
  }

  Future<void> _pickClass() async {
    if (_options.isEmpty) {
      return;
    }
    final SchoolClass? c = await showDialog<SchoolClass>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('اختر صفاً'),
        children: <Widget>[
          for (final SchoolClass o in _options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Text('${o.grade} ـ ${o.section}'),
            ),
        ],
      ),
    );
    if (c != null) {
      await _start(ClassRef(id: c.id, title: '${c.grade} ـ ${c.section}'));
    }
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setStatus(Student s, int? status) async {
    try {
      final AppDb db = ref.read(dbProvider);
      final Session? ses = await db.sessionOf(s.classId, _date);
      if (status == null) {
        await (db.delete(db.attendanceRows)
              ..where((a) => a.studentId.equals(s.id) & a.date.equals(_date)))
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
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'daySheet:setStatus');
      _snack('تعذر حفظ الحالة: $e');
    }
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
    bool schoolDay = true;
    try {
      final AppDb db = ref.read(dbProvider);
      final Map<String, String> s = await db.effectiveSettings();
      final Set<int> weekdays = <int>{
        for (final String w in (s['work_weekdays'] ?? '7,1,2,3,4').split(','))
          int.tryParse(w) ?? 0,
      };
      final Set<String> holidays = <String>{
        for (final Holiday h in await db.select(db.holidays).get()) h.date,
      };
      schoolDay = SchoolTime.isSchoolDay(
        SchoolTime.parseKey(_date),
        workWeekdays: weekdays,
        holidayKeys: holidays,
      );
    } catch (e, st) {
      // فشل قراءة الإعدادات لا يجوز أن يمنع الإقفال؛ نكتفي بتسجيله.
      AppErrorLog.instance.record(e, st, where: 'daySheet:schoolDay');
    }
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
    try {
      final AppDb db = ref.read(dbProvider);
      if (ses.closedAt == null) {
        final bool ok = await _confirmClose(missing);
        if (!ok) {
          return;
        }
        final int n = await db.closeSession(ses.id);
        _snack('أُقفل اليوم وولّد $n سجلاً');
      } else {
        await db.reopenSession(ses.id);
        _snack('أُعيد فتح اليوم؛ حُذفت السجلات التلقائية');
      }
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'daySheet:toggleClose');
      _snack('تعذر تغيير حالة الإقفال: $e');
    }
  }

  Future<int> _missingCount(AppDb db, int classId) async {
    final List<Student> roster = await (db.select(db.students)
          ..where((s) => s.classId.equals(classId)))
        .get();
    final int recorded = await db.recordedCount(classId, _date);
    return roster.length - recorded;
  }

  @override
  Widget build(BuildContext context) {
    final ClassRef? c = _class;
    return Scaffold(
      appBar: AppBar(
        title: Text(c == null ? 'كشف اليوم $_date' : 'كشف ${c.displayTitle} — $_date'),
        actions: <Widget>[
          if (c != null)
            IconButton(
              tooltip: 'شاشة المسح',
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: () => context.push(
                AppRoutes.classLocation('/scan', c.id, c.displayTitle),
                extra: c,
              ),
            ),
        ],
      ),
      body: _body(c),
    );
  }

  Widget _body(ClassRef? c) {
    if (_resolving) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? err = _resolveError;
    if (err != null) {
      return Center(
        child: LoadErrorCard(message: err, onRetry: () => _start(widget.classRef)),
      );
    }
    if (c == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.fact_check_outlined, size: 48),
              const SizedBox(height: 8),
              const Text('لم يُحدَّد صف لهذا الكشف.', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              if (_options.isNotEmpty)
                FilledButton.icon(
                  onPressed: _pickClass,
                  icon: const Icon(Icons.class_),
                  label: const Text('اختر صفاً'),
                )
              else
                FilledButton.icon(
                  onPressed: () => context.pushNamed(AppRoutes.classes),
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة صف'),
                ),
            ],
          ),
        ),
      );
    }
    final Stream<Session?>? sessionStream = _session;
    final Stream<List<Student>>? studentsStream = _students;
    final Stream<List<AttendanceRow>>? rowsStream = _rows;
    if (sessionStream == null || studentsStream == null || rowsStream == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: <Widget>[
        _SummaryBar(
          sessionStream: sessionStream,
          studentsStream: studentsStream,
          rowsStream: rowsStream,
          onToggleClose: (Session? ses) async {
            if (ses == null) {
              _snack('لم تُفتح جلسة لهذا اليوم بعد — افتحها من شاشة المسح');
              return;
            }
            try {
              final int m = await _missingCount(ref.read(dbProvider), c.id);
              await _toggleClose(ses, m);
            } catch (e, st) {
              AppErrorLog.instance.record(e, st, where: 'daySheet:close');
              _snack('تعذر إقفال اليوم: $e');
            }
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<_Filter>(
            segments: const <ButtonSegment<_Filter>>[
              ButtonSegment<_Filter>(value: _Filter.all, label: Text('الكل')),
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
          child: StreamGuard<List<Student>>(
            stream: studentsStream,
            builder: (BuildContext context, List<Student> roster) =>
                StreamGuard<List<AttendanceRow>>(
              stream: rowsStream,
              builder: (BuildContext context, List<AttendanceRow> rows) {
                final Map<int, int> byId = <int, int>{
                  for (final AttendanceRow r in rows) r.studentId: r.status,
                };
                final List<Student> shown = _filter == _Filter.missing
                    ? roster
                        .where((Student s) => !byId.containsKey(s.id))
                        .toList()
                    : roster;
                if (shown.isEmpty) {
                  return const Center(child: Text('لا طلاب في هذا النطاق'));
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
                      subtitle: Text('${statusHint(st)} • رقم ${s.seq}'),
                      trailing: const Icon(Icons.edit),
                      onTap: () => _pickStatus(s, st),
                      onLongPress: () => context.pushNamed(
                        AppRoutes.student,
                        pathParameters: <String, String>{'id': '${s.id}'},
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// شريط الملخّص: مسجل/الكل + حالة الجلسة + زر الإقفال/إعادة الفتح.
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
  final void Function(Session? session) onToggleClose;

  @override
  Widget build(BuildContext context) => StreamGuard<List<Student>>(
        stream: studentsStream,
        loading: const SizedBox(height: 68),
        builder: (BuildContext context, List<Student> students) =>
            StreamGuard<List<AttendanceRow>>(
          stream: rowsStream,
          loading: const SizedBox(height: 68),
          builder: (BuildContext context, List<AttendanceRow> rows) {
            final int total = students.length;
            final int recorded = rows
                .where(
                  (AttendanceRow r) =>
                      r.status == AttendanceStatus.present ||
                      r.status == AttendanceStatus.late ||
                      r.status == AttendanceStatus.leave,
                )
                .length;
            return StreamGuard<Session?>(
              stream: sessionStream,
              loading: const SizedBox(height: 68),
              builder: (BuildContext context, Session? ses) {
                final bool closed = ses?.closedAt != null;
                return Card(
                  margin: const EdgeInsets.all(8),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: <Widget>[
                        Text('مسجل: $recorded / $total'),
                        Text(ses == null ? 'لا جلسة' : (closed ? 'مقفلة' : 'مفتوحة')),
                        FilledButton.icon(
                          onPressed: () => onToggleClose(ses),
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
        ),
      );
}
