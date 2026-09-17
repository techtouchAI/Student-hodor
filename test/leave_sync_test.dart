import 'package:drift/drift.dart' hide isNull;
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
    expect(row?.note, AppDb.leaveSyncNote);

    final int removed = await db.syncLeaveToAttendance(
      studentId: stu,
      start: _date,
      end: _date,
      added: false,
    );
    expect(removed, 1);
    row = await db.attendanceOf(stu, _date);
    expect(row?.status, AttendanceStatus.absent);
    expect(row?.note, isNull);
  });

  test('إضافة إجازة تلغي الغياب اليدوي أيضاً وتحافظ على مصدره', () async {
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
    expect(added, 1);
    AttendanceRow? row = await db.attendanceOf(stu, _date);
    expect(row?.status, AttendanceStatus.leave);
    expect(row?.source, AttendanceSource.manual);
    expect(row?.note, AppDb.leaveSyncNote);

    final int removed = await db.syncLeaveToAttendance(
      studentId: stu,
      start: _date,
      end: _date,
      added: false,
    );
    expect(removed, 1);
    row = await db.attendanceOf(stu, _date);
    expect(row?.status, AttendanceStatus.absent);
    expect(row?.source, AttendanceSource.manual);
    expect(row?.note, isNull);
  });

  test('الحضور والتأخر والإجازة اليدوية لا تُمسّ بالمزامنة', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final (int cls, int stu) = await _seed(db);
    const List<(String, int, int)> rows = <(String, int, int)>[
      ('2026-09-13', AttendanceStatus.present, AttendanceSource.scan),
      ('2026-09-14', AttendanceStatus.late, AttendanceSource.scan),
      ('2026-09-15', AttendanceStatus.leave, AttendanceSource.manual),
    ];
    for (final (String, int, int) r in rows) {
      await db.upsertAttendance(
        yearId: 1,
        classId: cls,
        studentId: stu,
        date: r.$1,
        status: r.$2,
        source: r.$3,
      );
    }
    final int added = await db.syncLeaveToAttendance(
      studentId: stu,
      start: '2026-09-13',
      end: '2026-09-15',
      added: true,
    );
    expect(added, 0);
    final int removed = await db.syncLeaveToAttendance(
      studentId: stu,
      start: '2026-09-13',
      end: '2026-09-15',
      added: false,
    );
    expect(removed, 0);
    for (final (String, int, int) r in rows) {
      final AttendanceRow? row = await db.attendanceOf(stu, r.$1);
      expect(row?.status, r.$2);
      expect(row?.source, r.$3);
    }
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
