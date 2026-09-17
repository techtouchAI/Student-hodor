/// الإنذار المبكر: عتبة نسبة الغياب تُرشّح الطلاب، والترتيب بالأكثر
/// غياباً، ومن لا سجلات له خارج القائمة — العتبتان من إعدادات التطبيق.
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/reports_service.dart';

Future<AppDb> _seed() async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
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
  Future<void> student(String name, List<int> statuses) async {
    final int id = await db.addStudent(
      yearId: year,
      classId: cls,
      fullName: name,
    );
    for (int i = 0; i < statuses.length; i++) {
      await db.upsertAttendance(
        yearId: year,
        classId: cls,
        studentId: id,
        date: '2026-09-${(i + 1).toString().padLeft(2, '0')}',
        status: statuses[i],
        source: AttendanceSource.manual,
      );
    }
  }

  await student(
    'كثير الغياب',
    <int>[
      ...List<int>.filled(2, AttendanceStatus.absent),
      ...List<int>.filled(8, AttendanceStatus.present),
    ],
  );
  await student(
    'حدّي',
    <int>[
      AttendanceStatus.absent,
      ...List<int>.filled(9, AttendanceStatus.present),
    ],
  );
  await student('بلا سجلات', <int>[]);
  await student(
    'متأخر',
    <int>[
      AttendanceStatus.absent,
      ...List<int>.filled(9, AttendanceStatus.late),
    ],
  );
  return db;
}

void main() {
  test('العتبة الأولى تُدخل من تجاوزها مرتبين بالأكثر غياباً', () async {
    final AppDb db = await _seed();
    addTearDown(db.close);
    final AcademicYear year = (await db.activeYear())!;
    final List<(Student, StatusTotals)> list =
        await ReportsService(db).alerts(year.id, 10.0);
    expect(
      list.map((e) => e.$1.fullName),
      containsAll(<String>['كثير الغياب', 'حدّي', 'متأخر']),
    );
    expect(list.length, 3);
    expect(list.first.$1.fullName, 'كثير الغياب');
  });

  test('العتبة الثانية تُدخل الأشد فقط', () async {
    final AppDb db = await _seed();
    addTearDown(db.close);
    final AcademicYear year = (await db.activeYear())!;
    final List<(Student, StatusTotals)> list =
        await ReportsService(db).alerts(year.id, 15.0);
    expect(list.length, 1);
    expect(list.single.$1.fullName, 'كثير الغياب');
  });

  test('عتبة مستحيلة تُخرج قائمة فارغة', () async {
    final AppDb db = await _seed();
    addTearDown(db.close);
    final AcademicYear year = (await db.activeYear())!;
    final List<(Student, StatusTotals)> list =
        await ReportsService(db).alerts(year.id, 50.0);
    expect(list, isEmpty);
  });
}
