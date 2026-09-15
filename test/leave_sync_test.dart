import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';

const String _date = '2026-09-13';

Future<(int, int)> _seed(AppDb db) async {
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
  final int stu = await db.into(db.students).insert(
        StudentsCompanion(
          yearId: Value(year),
          classId: Value(cls),
          fullName: const Value('طالب واحد'),
          personKey: const Value('PK-1'),
          seq: const Value(1),
          createdAt: const Value('2026-09-01T08:00:00'),
        ),
      );
  return (cls, stu);
}

void main() {
  test('إضافة إجازة تحوّل الغياب التلقائي إلى إجازة وحذفها يعيده', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final (int cls, int stu) = await _seed(db);

    // غياب مولّد تلقائياً عند الإقفال
    await db.upsertAttendance(
      yearId: 1,
      classId: cls,
      studentId: stu,
      date: _date,
      status: AttendanceStatus.absent,
      source: AttendanceSource.autoClose,
    );

    final int added = await db.syncLeaveToAttendance(
      studentId: stu,
      start: _date,
      end: _date,
      added: true,
    );
    expect(added, 1);
    AttendanceRow? row = await db.attendanceOf(stu, _date);
    expect(row?.status, AttendanceStatus.leave);

    final int removed = await db.syncLeaveToAttendance(
      studentId: stu,
      start: _date,
      end: _date,
      added: false,
    );
    expect(removed, 1);
    row = await db.attendanceOf(stu, _date);
    expect(row?.status, AttendanceStatus.absent);
  });

  test('لا تلمس السجلات اليدوية أو المسوحة', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final (int cls, int stu) = await _seed(db);
    await db.upsertAttendance(
      yearId: 1,
      classId: cls,
      studentId: stu,
      date: _date,
      status: AttendanceStatus.absent,
      source: AttendanceSource.manual,
    );
    final int added = await db.syncLeaveToAttendance(
      studentId: stu,
      start: _date,
      end: _date,
      added: true,
    );
    expect(added, 0);
    final AttendanceRow? row = await db.attendanceOf(stu, _date);
    expect(row?.status, AttendanceStatus.absent);
  });

  test('upsertAttendance يحدّث السجل القائم ولا يكرره', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final (int cls, int stu) = await _seed(db);
    await db.upsertAttendance(
      yearId: 1,
      classId: cls,
      studentId: stu,
      date: _date,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
    );
    await db.upsertAttendance(
      yearId: 1,
      classId: cls,
      studentId: stu,
      date: _date,
      status: AttendanceStatus.late,
      source: AttendanceSource.manual,
    );
    final List<AttendanceRow> rows =
        await db.attendanceForClassDate(cls, _date);
    expect(rows.length, 1);
    expect(rows.single.status, AttendanceStatus.late);
    expect(rows.single.source, AttendanceSource.manual);
  });

  test('الفهارس تُنشأ عند إنشاء قاعدة جديدة', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'",
        )
        .get();
    expect(rows.length, greaterThanOrEqualTo(6));
  });
}
