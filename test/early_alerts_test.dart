/// الإنذار المبكر بدلالة **أيام الغياب** لا النسبة: العتبة من إعدادات
/// التطبيق، والترتيب بالأكثر غياباً، ومن لا سجلات له خارج القائمة.
/// طالب غاب يوماً واحداً من يوم (100%) لا يُنذَر بعتبة يومين.
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
      ...List<int>.filled(3, AttendanceStatus.absent),
      ...List<int>.filled(7, AttendanceStatus.present),
    ],
  );
  await student(
    'حدّي',
    <int>[
      ...List<int>.filled(2, AttendanceStatus.absent),
      ...List<int>.filled(8, AttendanceStatus.present),
    ],
  );
  await student('بلا سجلات', <int>[]);
  await student('يوم واحد', <int>[AttendanceStatus.absent]);
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
  test('العتبة الأولى تُدخل من بلغها أياماً مرتبين بالأكثر غياباً', () async {
    final AppDb db = await _seed();
    addTearDown(db.close);
    final AcademicYear year = (await db.activeYear())!;
    final List<(Student, StatusTotals)> list =
        await ReportsService(db).alerts(year.id, 2.0);
    final List<String> names = <String>[for (final e in list) e.$1.fullName];
    expect(names, contains('كثير الغياب'));
    expect(names, contains('حدّي'));
    expect(names, isNot(contains('يوم واحد')));
    expect(names, isNot(contains('بلا سجلات')));
    expect(names, isNot(contains('متأخر')));
    expect(list.length, 2);
    expect(list.first.$1.fullName, 'كثير الغياب');
  });

  test('العتبة الثانية تُدخل الأشد فقط', () async {
    final AppDb db = await _seed();
    addTearDown(db.close);
    final AcademicYear year = (await db.activeYear())!;
    final List<(Student, StatusTotals)> list =
        await ReportsService(db).alerts(year.id, 3.0);
    expect(list.length, 1);
    expect(list.single.$1.fullName, 'كثير الغياب');
  });

  test('عتبة عالية (كـ200 يوم) تُخرج قائمة فارغة', () async {
    final AppDb db = await _seed();
    addTearDown(db.close);
    final AcademicYear year = (await db.activeYear())!;
    final List<(Student, StatusTotals)> list =
        await ReportsService(db).alerts(year.id, 200.0);
    expect(list, isEmpty);
  });
}
