/// استعلامات التقارير والإحصاء والإنذار المبكر — بمقياسين صريحين:
///
/// - **الحصص**: عدد السجلات (حاضر/غائب/إجازة/متأخر) — تفصيل اليوم.
/// - **الأيام**: تواريخ متمايزة — أساس عتبات الإنذار وحد الفصل (تبقى قانونية
///   بيوم، فلا تتغير دلالة «15 يوماً» بعد إدخال الحصص).
///
/// كل مجاميع التطبيق والتصدير تمرّ من هنا، فلا يوجد حساب موازٍ في شاشة.
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
    this.absentDays = 0,
    this.recordedDays = 0,
  });

  /// عدد **الحصص** المسجّلة حاضراً.
  final int present;

  /// عدد **حصص** الغياب.
  final int absent;

  /// عدد **حصص** الإجازة.
  final int leave;

  /// عدد **حصص** التأخر.
  final int late;

  /// عدد **الأيام** التي فيها حصة غياب واحدة على الأقل (لا يتكرر اليوم).
  final int absentDays;

  /// عدد **الأيام** التي فيها أي تسجيل.
  final int recordedDays;

  /// مجموع الحصص المسجّلة.
  int get recorded => present + absent + leave + late;

  /// نسبة الحضور: الحضور الكامل + المتأخر يُحتسبان حضوراً.
  double get ratePct => recorded == 0 ? 100 : (present + late) * 100 / recorded;

  /// نسبة أيام الحضور (بلا يوم غياب) — سياق إضافي للتقارير.
  double get attendanceDaysPct => recordedDays == 0
      ? 100
      : (recordedDays - absentDays) * 100 / recordedDays;

  StatusTotals plus(int status) => StatusTotals(
        present: present + (status == AttendanceStatus.present ? 1 : 0),
        absent: absent + (status == AttendanceStatus.absent ? 1 : 0),
        leave: leave + (status == AttendanceStatus.leave ? 1 : 0),
        late: late + (status == AttendanceStatus.late ? 1 : 0),
        absentDays: absentDays,
        recordedDays: recordedDays,
      );

  StatusTotals merge(StatusTotals other) => StatusTotals(
        present: present + other.present,
        absent: absent + other.absent,
        leave: leave + other.leave,
        late: late + other.late,
        absentDays: absentDays + other.absentDays,
        recordedDays: recordedDays + other.recordedDays,
      );
}

/// خلية يوم في شبكة الشهر: الحالة المجمّعة + حالات الحصص كلها.
class DayCell {
  const DayCell(
    this.dateKey,
    this.status,
    this.isSchoolDay, {
    this.arrivalTime,
    this.lessonStatuses = const <int, int>{},
    this.lessonArrivals = const <int, String>{},
  });

  final String dateKey;

  /// الحالة المجمّعة لليوم (أخطر حالة فيه) — لون الشبكة وعنوانها.
  final int? status;

  final bool isSchoolDay;

  /// وقت الوصول الفعلي `HH:mm` للسجل المجمّع (تأخر خصوصاً).
  final String? arrivalTime;

  /// حالة كل حصة: lessonId ⇒ status. غياب مفتاح = لم تُسجَّل الحصة.
  final Map<int, int> lessonStatuses;

  /// وقت وصول كل حصة (lessonId ⇒ `HH:mm`) لعرض فقرة التأخير.
  final Map<int, String> lessonArrivals;

  bool get hasLessons => lessonStatuses.isNotEmpty;
}

/// يوم واحد في سجل الطالب الكامل (من بداية السنة حتى اليوم).
class RecordDay {
  const RecordDay({
    required this.dateKey,
    required this.status,
    required this.schoolDay,
    this.arrivalTime,
    this.lessonStatuses = const <int, int>{},
    this.lessonArrivals = const <int, String>{},
  });

  final String dateKey;
  final int? status;
  final bool schoolDay;
  final String? arrivalTime;
  final Map<int, int> lessonStatuses;
  final Map<int, String> lessonArrivals;
}

/// سجل الطالب الكامل: أيام النطاق + مجاميع السنة (المطابقة لبطاقة
/// المجاميع في ملف الطالب) — مصدر حقيقة واحد لتصدير Excel وPDF.
class StudentRecord {
  const StudentRecord({
    required this.from,
    required this.to,
    required this.days,
    required this.totals,
    this.byLesson = const <int, StatusTotals>{},
  });

  final String from;
  final String to;
  final List<RecordDay> days;
  final StatusTotals totals;

  /// مجاميع كل حصة على حدة (lessonId ⇒ totals) — أعمدة «غياب الحصة».
  final Map<int, StatusTotals> byLesson;
}

/// سطر في سجل الحصص التفصيلي (ورقة التصدير/صفحة PDF).
class LessonLogRow {
  const LessonLogRow({
    required this.student,
    required this.row,
    required this.lesson,
  });

  final Student student;
  final AttendanceRow row;
  final Lesson lesson;
}

class ReportsService {
  ReportsService(this.db);

  final AppDb db;

  /// مجاميع سجلات جاهزة (دالة نقية) — تُستخدم للتقارير ولاختبارات الوحدة.
  static StatusTotals totalsOfRows(Iterable<AttendanceRow> rows) {
    int present = 0;
    int absent = 0;
    int leave = 0;
    int late = 0;
    final Set<String> absentDates = <String>{};
    final Set<String> recordedDates = <String>{};
    for (final AttendanceRow r in rows) {
      recordedDates.add(r.date);
      switch (r.status) {
        case AttendanceStatus.present:
          present++;
        case AttendanceStatus.absent:
          absent++;
          absentDates.add(r.date);
        case AttendanceStatus.leave:
          leave++;
        case AttendanceStatus.late:
          late++;
      }
    }
    return StatusTotals(
      present: present,
      absent: absent,
      leave: leave,
      late: late,
      absentDays: absentDates.length,
      recordedDays: recordedDates.length,
    );
  }

  /// الحالة المجمّعة ليوم من حالات حصصه: أخطر حالة تغلب.
  ///
  /// الترتيب: غياب > إجازة > تأخر > حضور. الغياب في حصة واحدة يجعل اليوم
  /// «فيه غياب» ولو حضر بقية الحصص — وهو ما يبحث عنه المعلم في التقارير.
  static int? aggregateStatus(Iterable<int> statuses) {
    bool present = false;
    bool late = false;
    bool leave = false;
    for (final int s in statuses) {
      switch (s) {
        case AttendanceStatus.absent:
          return AttendanceStatus.absent;
        case AttendanceStatus.leave:
          leave = true;
        case AttendanceStatus.late:
          late = true;
        case AttendanceStatus.present:
          present = true;
      }
    }
    if (leave) {
      return AttendanceStatus.leave;
    }
    if (late) {
      return AttendanceStatus.late;
    }
    return present ? AttendanceStatus.present : null;
  }

  /// بناء خريطة يوم من صفوفه: الحالة المجمّعة + خرائط الحصص.
  static ({
    int? status,
    String? arrivalTime,
    Map<int, int> lessonStatuses,
    Map<int, String> lessonArrivals,
  }) summarizeDay(Iterable<AttendanceRow> rows) {
    final Map<int, int> statuses = <int, int>{};
    final Map<int, String> arrivals = <int, String>{};
    for (final AttendanceRow r in rows) {
      statuses[r.lessonId] = r.status;
      final String? at = r.arrivalTime;
      if (at != null) {
        arrivals[r.lessonId] = at;
      }
    }
    final int? status = aggregateStatus(statuses.values);
    String? arrival;
    if (status != null) {
      for (final AttendanceRow r in rows) {
        if (r.status == status && r.arrivalTime != null) {
          arrival = r.arrivalTime;
          break;
        }
      }
    }
    return (
      status: status,
      arrivalTime: arrival,
      lessonStatuses: statuses,
      lessonArrivals: arrivals,
    );
  }

  Future<List<AttendanceRow>> rowsOfStudent(int studentId, int yearId) =>
      (db.select(db.attendanceRows)
            ..where(
              (a) => a.studentId.equals(studentId) & a.yearId.equals(yearId),
            )
            ..orderBy(<OrderClauseGenerator<AttendanceRows>>[
              (AttendanceRows a) => OrderingTerm.asc(a.date),
              (AttendanceRows a) => OrderingTerm.asc(a.lessonId),
            ]))
          .get();

  Future<StatusTotals> totalsForStudent(int studentId, int yearId) async =>
      totalsOfRows(await rowsOfStudent(studentId, yearId));

  /// مجاميع كل حصة للطالب (lessonId ⇒ totals).
  Future<Map<int, StatusTotals>> totalsByLesson(
    int studentId,
    int yearId,
  ) async {
    final Map<int, List<AttendanceRow>> grouped = <int, List<AttendanceRow>>{};
    for (final AttendanceRow r in await rowsOfStudent(studentId, yearId)) {
      grouped.putIfAbsent(r.lessonId, () => <AttendanceRow>[]).add(r);
    }
    return <int, StatusTotals>{
      for (final MapEntry<int, List<AttendanceRow>> e in grouped.entries)
        e.key: totalsOfRows(e.value),
    };
  }

  /// خلايا شهر لطالب: أيام الشهر كلها مع حالتها وحالات حصصها.
  Future<List<DayCell>> monthCells({
    required int studentId,
    required int yearId,
    required int year,
    required int month,
    required Set<int> workWeekdays,
    required Set<String> holidayKeys,
  }) async {
    final DateTime first = DateTime(year, month, 1);
    final DateTime last = DateTime(year, month + 1, 0);
    final String from = SchoolTime.dateKey(first);
    final String to = SchoolTime.dateKey(last);
    // فلترة النطاق في SQL: كان السابق يجلب **كل** سجلات السنة لكل شهر.
    final List<AttendanceRow> rows = await (db.select(db.attendanceRows)
          ..where(
            (a) =>
                a.studentId.equals(studentId) &
                a.yearId.equals(yearId) &
                a.date.isBiggerOrEqualValue(from) &
                a.date.isSmallerOrEqualValue(to),
          ))
        .get();
    final Map<String, List<AttendanceRow>> byDate =
        <String, List<AttendanceRow>>{};
    for (final AttendanceRow r in rows) {
      byDate.putIfAbsent(r.date, () => <AttendanceRow>[]).add(r);
    }
    final List<DayCell> cells = <DayCell>[];
    for (final String key in SchoolTime.keysBetween(first, last)) {
      final ({
        int? status,
        String? arrivalTime,
        Map<int, int> lessonStatuses,
        Map<int, String> lessonArrivals,
      }) day = summarizeDay(byDate[key] ?? const <AttendanceRow>[]);
      cells.add(
        DayCell(
          key,
          day.status,
          SchoolTime.isSchoolDay(
            SchoolTime.parseKey(key),
            workWeekdays: workWeekdays,
            holidayKeys: holidayKeys,
          ),
          arrivalTime: day.arrivalTime,
          lessonStatuses: day.lessonStatuses,
          lessonArrivals: day.lessonArrivals,
        ),
      );
    }
    return cells;
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
    final List<AttendanceRow> all = await rowsOfStudent(studentId, year.id);
    final Map<String, List<AttendanceRow>> byDate =
        <String, List<AttendanceRow>>{};
    for (final AttendanceRow r in all) {
      byDate.putIfAbsent(r.date, () => <AttendanceRow>[]).add(r);
    }
    final List<RecordDay> days = <RecordDay>[];
    if (!end.isBefore(from)) {
      for (final String key in SchoolTime.keysBetween(from, end)) {
        final ({
          int? status,
          String? arrivalTime,
          Map<int, int> lessonStatuses,
          Map<int, String> lessonArrivals,
        }) day = summarizeDay(byDate[key] ?? const <AttendanceRow>[]);
        days.add(
          RecordDay(
            dateKey: key,
            status: day.status,
            schoolDay: SchoolTime.isSchoolDay(
              SchoolTime.parseKey(key),
              workWeekdays: workWeekdays,
              holidayKeys: holidayKeys,
            ),
            arrivalTime: day.arrivalTime,
            lessonStatuses: day.lessonStatuses,
            lessonArrivals: day.lessonArrivals,
          ),
        );
      }
    }
    final StatusTotals totals = totalsOfRows(all);
    return StudentRecord(
      from: SchoolTime.dateKey(from),
      to: SchoolTime.dateKey(end.isBefore(from) ? from : end),
      days: days,
      totals: totals,
      byLesson: await totalsByLesson(studentId, year.id),
    );
  }

  /// مصفوفة صف لحصة محددة: كل طالب وسجله في تلك الحصة (null = لم يُسجل) —
  /// السجل لا الحالة فقط لأن كشف الحصة يعرض وقت الوصول الفعلي للتأخر.
  Future<List<(Student, AttendanceRow?)>> classDayMatrix({
    required int classId,
    required String date,
    required int lessonId,
  }) async {
    final List<Student> roster = await (db.select(db.students)
          ..where((s) => s.classId.equals(classId))
          ..orderBy(<OrderClauseGenerator<Students>>[
            (Students s) => OrderingTerm.asc(s.fullName),
          ]))
        .get();
    final Map<int, AttendanceRow> rows = <int, AttendanceRow>{
      for (final AttendanceRow r in await (db.select(db.attendanceRows)
            ..where(
              (a) =>
                  a.classId.equals(classId) &
                  a.date.equals(date) &
                  a.lessonId.equals(lessonId),
            ))
          .get())
        r.studentId: r,
    };
    return <(Student, AttendanceRow?)>[
      for (final Student s in roster) (s, rows[s.id]),
    ];
  }

  /// مصفوفة صف ليوم كامل: لكل طالب خرائط حصصه (lessonId ⇒ سجل).
  Future<List<(Student, Map<int, AttendanceRow>)>> classDayLessonMatrix(
    int classId,
    String date,
  ) async {
    final List<Student> roster = await (db.select(db.students)
          ..where((s) => s.classId.equals(classId))
          ..orderBy(<OrderClauseGenerator<Students>>[
            (Students s) => OrderingTerm.asc(s.fullName),
          ]))
        .get();
    final Map<int, Map<int, AttendanceRow>> byStudent =
        <int, Map<int, AttendanceRow>>{};
    for (final AttendanceRow r in await db.attendanceForClassDate(classId, date)) {
      byStudent.putIfAbsent(r.studentId, () => <int, AttendanceRow>{})[
          r.lessonId] = r;
    }
    return <(Student, Map<int, AttendanceRow>)>[
      for (final Student s in roster)
        (s, byStudent[s.id] ?? <int, AttendanceRow>{}),
    ];
  }

  /// سجل الحصص التفصيلي لصفوف/طلاب محدّدين (ورقة التصدير).
  ///
  /// [monthKeys] فارغة = السنة كلها. [statuses] فارغة = كل الحالات، وإلا
  /// تُرشَّح (مثلاً الغياب وحده).
  Future<List<LessonLogRow>> lessonLog({
    required int yearId,
    required Iterable<int> studentIds,
    Set<String> monthKeys = const <String>{},
    Set<int> statuses = const <int>{},
  }) async {
    final List<int> ids = studentIds.toList();
    if (ids.isEmpty) {
      return <LessonLogRow>[];
    }
    final Map<int, Lesson> lessons = <int, Lesson>{
      for (final Lesson l in await db.allLessons()) l.id: l,
    };
    final Map<int, Student> students = <int, Student>{};
    for (final Student s in await (db.select(db.students)
          ..where((t) => t.id.isIn(ids)))
        .get()) {
      students[s.id] = s;
    }
    // شرط واحد مركّب (لا `where` متكرر على العبارة): الترشيح بالحالة جزء من
    // نفس الاستعلام فيبقى الفهرس فعّالاً والمنطق مقروءاً.
    final List<AttendanceRow> rows = await (db.select(db.attendanceRows)
          ..where(
            (a) =>
                a.yearId.equals(yearId) &
                a.studentId.isIn(ids) &
                (statuses.isEmpty
                    ? const Constant<bool>(true)
                    : a.status.isIn(statuses)),
          )
          ..orderBy(<OrderClauseGenerator<AttendanceRows>>[
            (AttendanceRows a) => OrderingTerm.asc(a.date),
            (AttendanceRows a) => OrderingTerm.asc(a.lessonId),
            (AttendanceRows a) => OrderingTerm.asc(a.studentId),
          ]))
        .get();
    final List<LessonLogRow> out = <LessonLogRow>[];
    for (final AttendanceRow r in rows) {
      if (monthKeys.isNotEmpty &&
          !monthKeys.contains(r.date.substring(0, 7))) {
        continue;
      }
      final Student? s = students[r.studentId];
      final Lesson? l = lessons[r.lessonId];
      if (s == null || l == null) {
        continue;
      }
      out.add(LessonLogRow(student: s, row: r, lesson: l));
    }
    return out;
  }

  /// طلاب تجاوزوا **أيام** غيابهم حدّ الإنذار.
  ///
  /// العتبة عدد أيام (لا نسبة مئوية ولا حصص): طالب غاب يوماً واحداً لا يُنذَر
  /// بعتبة 100، وحضوره في بقية حصص اليوم لا يمحو غيابه في حصة منه.
  Future<List<(Student, StatusTotals)>> alerts(
    int yearId,
    double thresholdDays,
  ) async {
    final List<Student> students =
        await (db.select(db.students)..where((s) => s.yearId.equals(yearId))).get();
    // استعلام تجميعي واحد لكل السنة بدل استعلام لكل طالب: هذا المسار يعمل بعد
    // **كل** تسجيل حضور (watcher التنبيهات)، وعدد السجلات يساوي الطلاب ×
    // الحصص × الأيام. التشغيل السابق كان O(طلاب × سجلات).
    final Map<int, StatusTotals> totals = await _totalsByStudent(yearId);
    final List<(Student, StatusTotals)> out = <(Student, StatusTotals)>[];
    for (final Student s in students) {
      final StatusTotals t = totals[s.id] ?? const StatusTotals();
      if (t.recorded > 0 && t.absentDays >= thresholdDays) {
        out.add((s, t));
      }
    }
    out.sort(
      (
        (Student, StatusTotals) a,
        (Student, StatusTotals) b,
      ) =>
          b.$2.absentDays.compareTo(a.$2.absentDays),
    );
    return out;
  }

  /// مجاميع كل طلاب سنة في استعلام واحد (نفس دلالة [totalsOfRows] تماماً:
  /// `absent` حصص، `absentDays` تواريخ متمايزة).
  Future<Map<int, StatusTotals>> _totalsByStudent(int yearId) async {
    final List<QueryRow> rows = await db.customSelect(
      'SELECT student_id, '
      'SUM(CASE WHEN status = ? THEN 1 ELSE 0 END) AS present_rows, '
      'SUM(CASE WHEN status = ? THEN 1 ELSE 0 END) AS absent_rows, '
      'SUM(CASE WHEN status = ? THEN 1 ELSE 0 END) AS leave_rows, '
      'SUM(CASE WHEN status = ? THEN 1 ELSE 0 END) AS late_rows, '
      'COUNT(DISTINCT date) AS recorded_days, '
      'COUNT(DISTINCT CASE WHEN status = ? THEN date END) AS absent_days '
      'FROM attendance_rows WHERE year_id = ? GROUP BY student_id',
      variables: <Variable<int>>[
        const Variable<int>(AttendanceStatus.present),
        const Variable<int>(AttendanceStatus.absent),
        const Variable<int>(AttendanceStatus.leave),
        const Variable<int>(AttendanceStatus.late),
        const Variable<int>(AttendanceStatus.absent),
        Variable<int>(yearId),
      ],
      readsFrom: {db.attendanceRows},
    ).get();
    return <int, StatusTotals>{
      for (final QueryRow r in rows)
        r.read<int>('student_id'): StatusTotals(
          present: r.read<int>('present_rows'),
          absent: r.read<int>('absent_rows'),
          leave: r.read<int>('leave_rows'),
          late: r.read<int>('late_rows'),
          recordedDays: r.read<int>('recorded_days'),
          absentDays: r.read<int>('absent_days'),
        ),
    };
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
