/// T2/R9: إقفال **كل حصص اليوم** وإعادة فتحها — ذرّية كاملة، بلا تكرار
/// سجلات، وبلا مسّ ما سُجّل يدوياً أو بإجازة.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/lesson.dart';
import 'package:student_hodor/data/db.dart';

const String _date = '2026-09-21';

Future<({AppDb db, int classId, List<Student> kids})> _seed({
  int students = 3,
}) async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final int yearId = await db.into(db.academicYears).insert(
        const AcademicYearsCompanion(
          name: Value('2026-2027'),
          start: Value('2026-09-01'),
          end: Value('2027-06-30'),
          active: Value(true),
        ),
      );
  final int classId = await db.into(db.schoolClasses).insert(
        SchoolClassesCompanion(
          yearId: Value(yearId),
          grade: const Value('السادس'),
          section: const Value('أ'),
        ),
      );
  for (int i = 1; i <= students; i++) {
    await db.addStudent(
      yearId: yearId,
      classId: classId,
      fullName: 'طالب $i',
    );
  }
  final List<Student> kids = await (db.select(db.students)
        ..orderBy(<OrderClauseGenerator<Students>>[
          (Students s) => OrderingTerm.asc(s.id),
        ]))
      .get();
  return (db: db, classId: classId, kids: kids);
}

Future<List<AttendanceRow>> _rowsOfDay(AppDb db) =>
    (db.select(db.attendanceRows)..where((a) => a.date.equals(_date))).get();

void main() {
  test('إقفال اليوم: ست حصص، لا تكرار، والإجازة لا تُمسّ', () async {
    final (db: AppDb db, classId: int classId, kids: List<Student> kids) =
        await _seed();
    addTearDown(db.close);
    final List<LessonWindow> lessons = await db.lessonWindows();
    expect(lessons.length, LessonSchedule.defaultCount);

    // الطالب 1 حاضر في الحصة الأولى (مسح)، الطالب 2 إجازة تغطي الحصتين 2 و3،
    // والطالب 3 بلا أي تسجيل.
    await db.upsertAttendance(
      yearId: 1,
      classId: classId,
      studentId: kids[0].id,
      date: _date,
      lessonId: lessons[0].id,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
      arrivalTime: '08:03',
    );
    await db.into(db.leaves).insert(
          LeavesCompanion.insert(
            yearId: 1,
            studentId: kids[1].id,
            start: _date,
            end: _date,
            fromSlot: const Value(2),
            toSlot: const Value(3),
            type: 0,
            createdAt: '2026-09-20T08:00:00',
          ),
        );

    final int generated = await db.closeDaySessions(
      yearId: 1,
      classId: classId,
      date: _date,
    );

    // 3 طلاب × 6 حصص = 18 موضعاً، منها حاضر واحد ⇒ 17 سطراً مولّداً.
    expect(generated, 17);
    expect(await _rowsOfDay(db), hasLength(18));

    final List<Session> sessions = await db.sessionsOfDay(classId, _date);
    expect(sessions, hasLength(lessons.length));
    expect(sessions.every((Session s) => s.closedAt != null), isTrue);

    // حضور الحصة الأولى بقي كما هو ولم يُمسّ.
    final AttendanceRow first = (await _rowsOfDay(db)).firstWhere(
      (AttendanceRow r) =>
          r.lessonId == lessons[0].id && r.studentId == kids[0].id,
    );
    expect(first.status, AttendanceStatus.present);
    expect(first.source, AttendanceSource.scan);
    expect(first.arrivalTime, '08:03');

    // إجازة الحصتين 2 و3 للطالب 2: إجازة بمصدر الإقفال التلقائي.
    for (final int index in <int>[1, 2]) {
      final AttendanceRow leaveRow = (await _rowsOfDay(db)).firstWhere(
        (AttendanceRow r) =>
            r.lessonId == lessons[index].id && r.studentId == kids[1].id,
      );
      expect(leaveRow.status, AttendanceStatus.leave);
    }
    // وخارج نطاق إجازته غائب.
    final AttendanceRow outside = (await _rowsOfDay(db)).firstWhere(
      (AttendanceRow r) =>
          r.lessonId == lessons[5].id && r.studentId == kids[1].id,
    );
    expect(outside.status, AttendanceStatus.absent);

    // إقفال ثانٍ لا يضاعف شيئاً.
    expect(
      await db.closeDaySessions(yearId: 1, classId: classId, date: _date),
      0,
    );
    expect(await _rowsOfDay(db), hasLength(18));

    // إعادة فتح الكل: يحذف المولَّد تلقائياً فقط ويصفّر تاريخ الإقفال.
    final int reopened = await db.reopenDaySessions(
      yearId: 1,
      classId: classId,
      date: _date,
    );
    expect(reopened, lessons.length);
    final List<AttendanceRow> after = await _rowsOfDay(db);
    expect(after, hasLength(1), reason: 'يبقى الحضور اليدوي وحده');
    expect(after.single.status, AttendanceStatus.present);
    final List<Session> sessionsAfter = await db.sessionsOfDay(classId, _date);
    expect(sessionsAfter.every((Session s) => s.closedAt == null), isTrue);
  });

  test('إقفال اليوم ذرّي: فشل لاحق يردّ كل سجلات الإقفال', () async {
    final (db: AppDb db, classId: int classId, kids: List<Student> kids) =
        await _seed(students: 1);
    addTearDown(db.close);

    await expectLater(
      db.transaction<void>(() async {
        await db.closeDaySessions(yearId: 1, classId: classId, date: _date);
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );

    expect(await _rowsOfDay(db), isEmpty, reason: 'لا سطر غياب بعد الارتداد');
    final List<Session> sessions = await db.sessionsOfDay(classId, _date);
    expect(
      sessions.every((Session s) => s.closedAt == null),
      isTrue,
      reason: 'ولا جلسة تبقى مقفلة',
    );
    expect(kids, hasLength(1));
  });

  test('إعادة فتح اليوم ذرّية: فشل لاحق يُبقي الحصص مقفلة', () async {
    final (db: AppDb db, classId: int classId, kids: List<Student> kids) =
        await _seed(students: 1);
    addTearDown(db.close);
    await db.closeDaySessions(yearId: 1, classId: classId, date: _date);
    final int rowsBefore = (await _rowsOfDay(db)).length;
    expect(rowsBefore, LessonSchedule.defaultCount);

    await expectLater(
      db.transaction<void>(() async {
        await db.reopenDaySessions(yearId: 1, classId: classId, date: _date);
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );

    final List<Session> sessions = await db.sessionsOfDay(classId, _date);
    expect(
      sessions.every((Session s) => s.closedAt != null),
      isTrue,
      reason: 'الارتداد أعاد تاريخ الإقفال',
    );
    expect(await _rowsOfDay(db), hasLength(rowsBefore));
    expect(kids, hasLength(1));
  });
}
