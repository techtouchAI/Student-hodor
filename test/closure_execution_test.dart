import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/closure_scheduler.dart';
import 'package:student_hodor/data/db.dart';

/// اختبارات تنفيذ الإقفال التلقائي: توليد الغياب، احترام الحضور/التأخير/
/// الإجازة/العطلة، عدم التكرار، وإعادة الفتح.
void main() {
  late AppDb db;
  const String date = '2026-09-16';

  setUp(() async {
    db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
  });

  /// سنة فعّالة + صف واحد + سبعة طلاب.
  Future<({int cls, List<Student> roster, Lesson lesson})> setup() async {
    final int year = await db.into(db.academicYears).insert(
          const AcademicYearsCompanion(
            name: Value('2026-2027'),
            start: Value('2026-09-01'),
            end: Value('2027-06-30'),
            active: Value(true),
          ),
        );
    final int cls = await db.into(db.schoolClasses).insert(
      SchoolClassesCompanion(
        yearId: Value(year),
        grade: const Value('السادس'),
        section: const Value('أ'),
      ),
    );
    final List<Student> roster = <Student>[];
    for (int i = 1; i <= 7; i++) {
      final int id = await db.into(db.students).insert(
        StudentsCompanion(
          yearId: Value(year),
          classId: Value(cls),
          fullName: Value('طالب $i'),
          personKey: Value('p$i'),
          seq: Value(i),
          createdAt: const Value('2026-09-01T08:00:00'),
        ),
      );
      roster.add(
        (await (db.select(db.students)..where((s) => s.id.equals(id)))
                .getSingle()),
      );
    }
    return (cls: cls, roster: roster, lesson: await db.firstLesson());
  }

  Future<void> arm(int classId, Lesson lesson) async {
    await db.upsertClosureTask(
      yearId: 1,
      classId: classId,
      date: date,
      lessonId: lesson.id,
      targetAt: '2026-09-16T08:45:00',
    );
  }

  Future<Map<int, int>> studentStatuses() async => <int, int>{
        for (final AttendanceRow r in await db.select(db.attendanceRows).get())
          r.studentId: r.status,
      };

  test('إقفال تلقائي يولّد غياباً لمن لم يسجل ويُبقي الحضور والتأخير', () async {
    final s = await setup();
    await db.upsertAttendance(
      yearId: 1,
      classId: s.cls,
      studentId: s.roster[0].id,
      lessonId: s.lesson.id,
      date: date,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
    );
    await db.upsertAttendance(
      yearId: 1,
      classId: s.cls,
      studentId: s.roster[1].id,
      lessonId: s.lesson.id,
      date: date,
      status: AttendanceStatus.late,
      source: AttendanceSource.scan,
    );
    await arm(s.cls, s.lesson);

    final int executed = await ClosureScheduler(db)
        .recoverDue(now: DateTime(2026, 9, 16, 9, 0));
    expect(executed, 1);

    final statusByStudent = await studentStatuses();
    expect(statusByStudent, hasLength(7));
    expect(statusByStudent[s.roster[0].id], AttendanceStatus.present,
        reason: 'الحاضر يبقى حاضراً',);
    expect(statusByStudent[s.roster[1].id], AttendanceStatus.late,
        reason: 'المتأخر يبقى متأخراً ولا يُحوَّل غائباً',);
    for (int i = 2; i < 7; i++) {
      expect(statusByStudent[s.roster[i].id], AttendanceStatus.absent,
          reason: 'من لم يسجل يُحتسب غائباً',);
    }
  });

  test('الإجازة تمنع الغياب (يوم كامل وجزئي لحصة أخرى)', () async {
    final s = await setup();
    // طالب 3: إجازة يوم كامل.
    await db.into(db.leaves).insert(
      LeavesCompanion.insert(
        yearId: 1,
        studentId: s.roster[2].id,
        start: date,
        end: date,
        type: 0,
        createdAt: '2026-09-15T08:00:00',
      ),
    );
    // طالب 4: إجازة جزئية للحصة الثانية فقط — لا تشمل الحصة الأولى.
    await db.into(db.leaves).insert(
      LeavesCompanion.insert(
        yearId: 1,
        studentId: s.roster[3].id,
        start: date,
        end: date,
        fromSlot: const Value<int?>(2),
        toSlot: const Value<int?>(2),
        type: 1,
        createdAt: '2026-09-15T08:00:00',
      ),
    );
    await arm(s.cls, s.lesson);

    final int executed = await ClosureScheduler(db)
        .recoverDue(now: DateTime(2026, 9, 16, 9, 0));
    expect(executed, 1);

    final statusByStudent = await studentStatuses();
    expect(statusByStudent[s.roster[2].id], AttendanceStatus.leave,
        reason: 'إجازة يوم كامل ⇒ إجازة لا غياب',);
    expect(statusByStudent[s.roster[3].id], AttendanceStatus.absent,
        reason: 'الإجازة الجزئية لحصة أخرى لا تُغطّي هذه الحصة',);
  });

  test('إجازة أُضيفت بعد الإقفال تُحوّل الغياب لإجازة ولا تُحذف السجل',
      () async {
    final s = await setup();
    await arm(s.cls, s.lesson);
    await ClosureScheduler(db).recoverDue(now: DateTime(2026, 9, 16, 9, 0));

    final AttendanceRow? row = await (db.select(db.attendanceRows)
            ..where((r) => r.studentId.equals(s.roster[2].id)))
        .getSingleOrNull();
    expect(row?.status, AttendanceStatus.absent);

    // إضافة إجازة لاحقاً: تُحوّل (لا تُحذف، لا تُنسَخ).
    final int synced = await db.syncLeaveToAttendance(
      studentId: s.roster[2].id,
      start: date,
      end: date,
      added: true,
    );
    expect(synced >= 1, isTrue);
    final AttendanceRow after = await (db.select(db.attendanceRows)
            ..where((r) => r.studentId.equals(s.roster[2].id)))
        .getSingle();
    expect(after.status, AttendanceStatus.leave,
        reason: 'الغياب يتحول لإجازة في مكانه',);
    expect(await db.select(db.attendanceRows).get(), hasLength(7),
        reason: 'لا سجل غياب مكرر',);
  });

  test('حذف الإجازة بعد الإقفال يعيد الغياب (إعادة احتساب)', () async {
    final s = await setup();
    await db.into(db.leaves).insert(
      LeavesCompanion.insert(
        yearId: 1,
        studentId: s.roster[2].id,
        start: date,
        end: date,
        type: 0,
        createdAt: '2026-09-15T08:00:00',
      ),
    );
    await arm(s.cls, s.lesson);
    await ClosureScheduler(db).recoverDue(now: DateTime(2026, 9, 16, 9, 0));

    await db.delete(db.leaves).go();
    await db.syncLeaveToAttendance(
      studentId: s.roster[2].id,
      start: date,
      end: date,
      added: false,
    );

    final AttendanceRow after = await (db.select(db.attendanceRows)
            ..where((r) => r.studentId.equals(s.roster[2].id)))
        .getSingle();
    expect(after.status, AttendanceStatus.absent,
        reason: 'بدون إجازة يعود الغياب',);
  });

  test('إعادة فتح الحصة ثم مهمة إقفال لا تُولّد غياباً مكرراً', () async {
    final s = await setup();
    await db.upsertAttendance(
      yearId: 1,
      classId: s.cls,
      studentId: s.roster[0].id,
      lessonId: s.lesson.id,
      date: date,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
    );
    await arm(s.cls, s.lesson);
    await ClosureScheduler(db).recoverDue(now: DateTime(2026, 9, 16, 9, 0));

    // إعادة فتح: الجلسة تُفتح مجدّداً، والمهمة تبقى سجل انتهاء.
    final Session? session = await db.sessionOf(s.cls, date, s.lesson.id);
    expect(session?.closedAt, isNotNull);
    await db.reopenSession(session!.id);
    final Session? reopened = await db.sessionOf(s.cls, date, s.lesson.id);
    expect(reopened?.closedAt, isNull);

    // استرداد لاحق لا يُعيد الإقفال (المهمة منفّذة): لا غياب مكرر.
    expect(await ClosureScheduler(db).recoverDue(now: DateTime(2026, 9, 16, 10, 0)), 0);
    // إعادة الفتح تحذف السجلات المولّدة تلقائياً (source=autoClose) وتبقي
    // الحضور المسجل بالمسح.
    expect(await db.select(db.attendanceRows).get(), hasLength(1),
        reason: 'الغيابات المولّدة تُحذف، والحضور المسجل يبقى',);
  });

  test('الإقفال التلقائي يسجّل في سجل التدقيق', () async {
    final s = await setup();
    await arm(s.cls, s.lesson);
    await ClosureScheduler(db).recoverDue(now: DateTime(2026, 9, 16, 9, 0));

    final List<AuditLog> logs = await db.select(db.auditLogs).get();
    expect(
      logs.where((AuditLog l) => l.action == 'closure_auto_closed').length,
      1,
    );
  });

  test('يوم عطلة: لا مهمة ولا غياب من الجدولة', () async {
    await setup();
    await db.into(db.holidays).insert(
      const HolidaysCompanion(date: Value(date), title: Value('عطلة')),
    );
    final DateTime now = DateTime(2026, 9, 16, 7, 0);
    final int armed = await ClosureScheduler(db).refreshSchedule(now: now);
    expect(await db.pendingClosureTasks(), isEmpty);
    expect(
        await ClosureScheduler(db)
            .recoverDue(now: now.add(const Duration(hours: 3))),
        0,);
    expect(armed, 0);
  });

  test('المسح بعد الإقفال يسجل حضوراً ولا يغيّر مهمة الإقفال', () async {
    final s = await setup();
    await arm(s.cls, s.lesson);
    await ClosureScheduler(db).recoverDue(now: DateTime(2026, 9, 16, 9, 0));

    // مسح طالب لم يسجل: يظهر كحاضر، ولا يُؤثّر على مهمة الإقفال.
    await db.upsertAttendance(
      yearId: 1,
      classId: s.cls,
      studentId: s.roster[2].id,
      lessonId: s.lesson.id,
      date: date,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
    );
    final AttendanceRow row = await (db.select(db.attendanceRows)
            ..where((r) => r.studentId.equals(s.roster[2].id)))
        .getSingle();
    expect(row.status, AttendanceStatus.present);
    final ClosureTask? task = await db.closureTaskOf(s.cls, date, s.lesson.id);
    expect(task?.state, ClosureTaskState.executed);
  });
}
