/// استعلامات التقارير والإحصاء والإنذار المبكر.
library;

import 'package:drift/drift.dart';

import '../core/school_time.dart';
import 'db.dart';

class StatusTotals {
  const StatusTotals({
    this.present = 0,
    this.absent = 0,
    this.leave = 0,
    this.late = 0,
  });

  final int present;
  final int absent;
  final int leave;
  final int late;

  int get recorded => present + absent + leave + late;

  /// نسبة الحضور: الحضور الكامل + المتأخر يُحتسبان حضوراً.
  double get ratePct => recorded == 0 ? 100 : (present + late) * 100 / recorded;
}

class DayCell {
  const DayCell(this.dateKey, this.status, this.isSchoolDay);

  final String dateKey;
  final int? status;
  final bool isSchoolDay;
}

/// يوم واحد في سجل الطالب الكامل (من بداية السنة حتى اليوم).
class RecordDay {
  const RecordDay({
    required this.dateKey,
    required this.status,
    required this.schoolDay,
  });

  final String dateKey;
  final int? status;
  final bool schoolDay;
}

/// سجل الطالب الكامل: أيام النطاق + مجاميع السنة (المطابقة لبطاقة
/// المجاميع في ملف الطالب) — مصدر حقيقة واحد لتصدير Excel وPDF.
class StudentRecord {
  const StudentRecord({
    required this.from,
    required this.to,
    required this.days,
    required this.totals,
  });

  final String from;
  final String to;
  final List<RecordDay> days;
  final StatusTotals totals;
}

class ReportsService {
  ReportsService(this.db);

  final AppDb db;

  Future<StatusTotals> totalsForStudent(int studentId, int yearId) async {
    final List<AttendanceRow> rows = await (db.select(db.attendanceRows)
          ..where((a) => a.studentId.equals(studentId) & a.yearId.equals(yearId)))
        .get();
    final StatusTotals t = rows.fold(
      const StatusTotals(),
      (StatusTotals acc, AttendanceRow r) => StatusTotals(
        present: acc.present + (r.status == AttendanceStatus.present ? 1 : 0),
        absent: acc.absent + (r.status == AttendanceStatus.absent ? 1 : 0),
        leave: acc.leave + (r.status == AttendanceStatus.leave ? 1 : 0),
        late: acc.late + (r.status == AttendanceStatus.late ? 1 : 0),
      ),
    );
    return t;
  }

  /// خلايا شهر لطالب: أيام الشهر كلها مع حالتها (null لغير المسجل/عطلة).
  Future<List<DayCell>> monthCells({
    required int studentId,
    required int yearId,
    required int year,
    required int month,
    required Set<int> workWeekdays,
    required Set<String> holidayKeys,
  }) async {
    final Map<String, int> byDate = <String, int>{
      for (final AttendanceRow r in await (db.select(db.attendanceRows)
            ..where((a) => a.studentId.equals(studentId) & a.yearId.equals(yearId)))
          .get())
        r.date: r.status,
    };
    final DateTime first = DateTime(year, month, 1);
    final DateTime last = DateTime(year, month + 1, 0);
    return <DayCell>[
      for (final String key in SchoolTime.keysBetween(first, last))
        DayCell(
          key,
          byDate[key],
          SchoolTime.isSchoolDay(
            SchoolTime.parseKey(key),
            workWeekdays: workWeekdays,
            holidayKeys: holidayKeys,
          ),
        ),
    ];
  }

  /// سجل طالب كامل من بداية السنة حتى اليوم (مكبوتاً بنهاية السنة) —
  /// يستهلكه تصدير Excel وPDF من ملف الطالب.
  Future<StudentRecord> studentRecord({
    required int studentId,
    required AcademicYear year,
    required Set<int> workWeekdays,
    required Set<String> holidayKeys,
    DateTime? today,
  }) async {
    final DateTime now = today ?? DateTime.now();
    DateTime end = DateTime(now.year, now.month, now.day);
    final DateTime yearEnd = SchoolTime.parseKey(year.end);
    if (end.isAfter(yearEnd)) {
      end = yearEnd;
    }
    final DateTime from = SchoolTime.parseKey(year.start);
    final Map<String, int> byDate = <String, int>{
      for (final AttendanceRow r in await (db.select(db.attendanceRows)
            ..where(
              (a) =>
                  a.studentId.equals(studentId) & a.yearId.equals(year.id),
            ))
          .get())
        r.date: r.status,
    };
    final List<RecordDay> days = end.isBefore(from)
        ? <RecordDay>[]
        : <RecordDay>[
            for (final String key
                in SchoolTime.keysBetween(from, end))
              RecordDay(
                dateKey: key,
                status: byDate[key],
                schoolDay: SchoolTime.isSchoolDay(
                  SchoolTime.parseKey(key),
                  workWeekdays: workWeekdays,
                  holidayKeys: holidayKeys,
                ),
              ),
          ];
    final StatusTotals totals = await totalsForStudent(studentId, year.id);
    return StudentRecord(
      from: SchoolTime.dateKey(from),
      to: SchoolTime.dateKey(end.isBefore(from) ? from : end),
      days: days,
      totals: totals,
    );
  }

  /// مصفوفة صف ليوم محدد: كل طالب وحالته (null = لم يُسجل بعد).
  Future<List<(Student, int?)>> classDayMatrix(int classId, String date) async {
    final List<Student> roster = await (db.select(db.students)
          ..where((s) => s.classId.equals(classId))
          ..orderBy(<OrderClauseGenerator<Students>>[
            (Students s) => OrderingTerm.asc(s.fullName),
          ]))
        .get();
    final Map<int, int> status = <int, int>{
      for (final AttendanceRow r in await (db.select(db.attendanceRows)
            ..where((a) => a.classId.equals(classId) & a.date.equals(date)))
          .get())
        r.studentId: r.status,
    };
    return <(Student, int?)>[
      for (final Student s in roster) (s, status[s.id]),
    ];
  }

  /// طلاب تجاوزوا نسبة غياب حدّ الإنذار.
  Future<List<(Student, StatusTotals)>> alerts(
    int yearId,
    double thresholdPct,
  ) async {
    final List<Student> students =
        await (db.select(db.students)..where((s) => s.yearId.equals(yearId))).get();
    final List<(Student, StatusTotals)> out = <(Student, StatusTotals)>[];
    for (final Student s in students) {
      final StatusTotals t = await totalsForStudent(s.id, yearId);
      if (t.recorded > 0 && (t.absent * 100 / t.recorded) >= thresholdPct) {
        out.add((s, t));
      }
    }
    out.sort(
      (
        (Student, StatusTotals) a,
        (Student, StatusTotals) b,
      ) =>
          b.$2.absent.compareTo(a.$2.absent),
    );
    return out;
  }

  /// سجل طالب عبر السنوات (personKey) — مسيرة الطالب.
  Future<List<(AcademicYear, StatusTotals)>> studentJourney(Student s) async {
    final List<AcademicYear> years =
        await (db.select(db.academicYears)..orderBy(<OrderClauseGenerator<AcademicYears>>[
              (AcademicYears y) => OrderingTerm.asc(y.start),
            ]))
            .get();
    final List<(AcademicYear, StatusTotals)> out = <(AcademicYear, StatusTotals)>[];
    for (final AcademicYear y in years) {
      final List<Student> same = await (db.select(db.students)
            ..where((t) => t.personKey.equals(s.personKey) & t.yearId.equals(y.id)))
          .get();
      if (same.isEmpty) {
        continue;
      }
      final StatusTotals t = await totalsForStudent(same.first.id, y.id);
      if (t.recorded > 0) {
        out.add((y, t));
      }
    }
    return out;
  }
}
