import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';

Future<int> _seed(AppDb db) async {
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
  for (int i = 1; i <= 3; i++) {
    await db.into(db.students).insert(
          StudentsCompanion(
            yearId: Value(year),
            classId: Value(cls),
            fullName: Value('طالب $i'),
            personKey: Value('p$i'),
            seq: Value(i),
            createdAt: const Value('2026-09-01T08:00:00'),
          ),
        );
  }
  return cls;
}

void main() {
  test('إقفال الجلسة يولّد غياباً لمن لم يُسجّل ويحترم الإجازة', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int cls = await _seed(db);
    final List<Student> roster =
        await (db.select(db.students)..where((s) => s.classId.equals(cls))).get();
    const String date = '2026-09-13';

    // طالب 1 حاضر بالمسح، طالب 2 بإجازة، طالب 3 بلا تسجيل.
    await db.upsertAttendance(
      yearId: 1,
      classId: cls,
      studentId: roster[0].id,
      date: date,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
    );
    await db.into(db.leaves).insert(
          LeavesCompanion(
            yearId: const Value(1),
            studentId: Value(roster[1].id),
            start: const Value(date),
            end: const Value(date),
            type: const Value(0),
            createdAt: const Value('2026-09-13T07:00:00'),
          ),
        );

    final int session = await db.into(db.sessions).insert(
          SessionsCompanion(
            yearId: const Value(1),
            classId: Value(cls),
            date: const Value(date),
            openedAt: const Value('2026-09-13T07:30:00'),
          ),
        );
    final int generated = await db.closeSession(session);
    expect(generated, 2);

    final AttendanceRow? a2 = await db.attendanceOf(roster[1].id, date);
    final AttendanceRow? a3 = await db.attendanceOf(roster[2].id, date);
    expect(a2?.status, AttendanceStatus.leave);
    expect(a3?.status, AttendanceStatus.absent);
    expect(a3?.source, AttendanceSource.autoClose);

    // إقفال ثانٍ لا يضاعف السجلات.
    expect(await db.closeSession(session), 0);

    // إعادة الفتح تحذف المولّد تلقائياً وتبقي المسح اليدوي.
    await db.reopenSession(session);
    expect(await db.attendanceOf(roster[2].id, date), isNull);
    expect(await db.attendanceOf(roster[0].id, date), isNotNull);
  });
}
