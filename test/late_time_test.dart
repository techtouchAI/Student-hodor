/// وقت التأخر الفعلي: أدوات التنسيق وحساب المدة + تثبيت المسح وقت الوصول
/// (ساعة ودقيقة حسب الوقت الفعلي) + حفظ الوقت ومسحه عند تغيير السجل يدوياً.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/late_time.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/scan_service.dart';

/// سنة فعّالة وصف وطالبان مع باجاتهما ([AppDb.addStudent] ينشئ الباج).
Future<(AppDb, AcademicYear, SchoolClass, List<Student>)> _seed() async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await db.setSetting('school_name', 'مدرسة النجاح');
  await db.setSetting('day_start', '08:00');
  await db.setSetting('late_after_minutes', '15');
  await db.into(db.academicYears).insert(
        const AcademicYearsCompanion(
          name: Value('2026-2027'),
          start: Value('2026-09-01'),
          end: Value('2027-06-30'),
          active: Value(true),
        ),
      );
  final AcademicYear year = (await db.activeYear())!;
  final int classId = await db.into(db.schoolClasses).insert(
        SchoolClassesCompanion(
          yearId: Value(year.id),
          grade: const Value('السادس'),
          section: const Value('أ'),
        ),
      );
  final List<Student> students = <Student>[];
  for (final String name in <String>['علي حسن', 'زيد كريم']) {
    final int id = await db.addStudent(
      yearId: year.id,
      classId: classId,
      fullName: name,
    );
    students.add((await db.studentById(id))!);
  }
  final SchoolClass cls = await (db.select(db.schoolClasses)
        ..where((c) => c.id.equals(classId)))
      .getSingle();
  return (db, year, cls, students);
}

void main() {
  group('أدوات وقت التأخر', () {
    test('تنسيق الوقت وتحليله', () {
      expect(arrivalTimeString(DateTime(2026, 9, 13, 8, 5)), '08:05');
      expect(arrivalTimeString(DateTime(2026, 9, 13, 13, 47)), '13:47');
      expect(parseArrivalMinutes('08:05'), 8 * 60 + 5);
      expect(parseArrivalMinutes(null), isNull);
      expect(parseArrivalMinutes('bad'), isNull);
      expect(parseArrivalMinutes('25:00'), isNull);
      expect(parseArrivalMinutes('08:60'), isNull);
    });

    test('مدة التأخر وصيغتها العربية', () {
      expect(lateDurationLabel(const Duration(minutes: 25)), '25 دقيقة');
      expect(lateDurationLabel(const Duration(minutes: 60)), 'ساعة');
      expect(
        lateDurationLabel(const Duration(minutes: 70)),
        'ساعة و10 دقائق',
      );
      expect(
        lateDurationLabel(const Duration(minutes: 125)),
        'ساعتان و5 دقائق',
      );
      expect(
        lateDurationLabel(const Duration(minutes: 185)),
        '3 ساعات و5 دقائق',
      );
      expect(lateDurationLabel(Duration.zero), '');
      final Duration d = latenessDuration(
        arrivalTime: '08:25',
        dayStart: '08:00',
      );
      expect(d.inMinutes, 25);
      expect(
        latenessDuration(arrivalTime: '07:50', dayStart: '08:00'),
        Duration.zero,
        reason: 'الوصول قبل بداية الدوام ليس تأخراً',
      );
      expect(
        latenessDuration(arrivalTime: null),
        Duration.zero,
        reason: 'سجل بلا وقت لا مدة له',
      );
    });

    test('سطر عرض المتأخر بحسب المعطيات', () {
      expect(lateInfoLabel(arrivalTime: null), 'متأخر');
      expect(
        lateInfoLabel(arrivalTime: '08:23', dayStart: '08:00'),
        'متأخر — الساعة 08:23 (تأخير 23 دقيقة)',
      );
      expect(
        lateInfoLabel(arrivalTime: '08:23'),
        'متأخر — الساعة 08:23',
        reason: 'بلا بداية دوام معروفة يعرض الوقت وحده',
      );
    });
  });

  group('المسح يثبّت وقت الوصول الفعلي', () {
    test('بعد نافذة السماح: متأخر مع وقته، وقبلها: حاضر مع وقته', () async {
      final (
        AppDb db,
        AcademicYear year,
        SchoolClass cls,
        List<Student> kids,
      ) = await _seed();
      addTearDown(db.close);
      const String date = '2026-09-13';
      await db.into(db.sessions).insert(
            SessionsCompanion(
              yearId: Value(year.id),
              classId: Value(cls.id),
              date: const Value(date),
              openedAt: const Value('2026-09-13T07:30:00'),
            ),
          );
      final Session session = (await db.sessionOf(cls.id, date))!;
      final ScanService scanner = ScanService(db);

      final Badge b1 = (await db.activeBadgeOf(kids[0].id))!;
      final ScanOutcome lateOut = await scanner.handleScan(
        session: session,
        raw: b1.code,
        now: DateTime(2026, 9, 13, 8, 20),
      );
      expect(lateOut.result, ScanResult.late);
      expect(lateOut.arrivalTime, '08:20');
      expect(lateOut.message, contains('08:20'));
      // المدة من بداية الدوام (08:00) لا من نهاية نافذة السماح.
      expect(lateOut.message, contains('تأخير 20 دقيقة'));
      final AttendanceRow? a1 = await db.attendanceOf(kids[0].id, date);
      expect(a1?.status, AttendanceStatus.late);
      expect(a1?.arrivalTime, '08:20');

      final Badge b2 = (await db.activeBadgeOf(kids[1].id))!;
      final ScanOutcome okOut = await scanner.handleScan(
        session: session,
        raw: b2.code,
        now: DateTime(2026, 9, 13, 8, 5),
      );
      expect(okOut.result, ScanResult.ok);
      expect(okOut.arrivalTime, '08:05');
      final AttendanceRow? a2 = await db.attendanceOf(kids[1].id, date);
      expect(a2?.status, AttendanceStatus.present);
      expect(a2?.arrivalTime, '08:05');
    });

    test('نافذة السماح: بداية الدوام + دقائق السماح من الإعدادات', () {
      final DateTime cutoff = ScanService.lateCutoff(
        <String, String>{'day_start': '07:30', 'late_after_minutes': '10'},
        '2026-09-13',
      );
      expect(cutoff, DateTime(2026, 9, 13, 7, 40));
    });
  });

  group('الوقت في سجل الحضور', () {
    test('تغيير الحالة يدوياً بلا وقت يمسح الوقت السابق', () async {
      final (
        AppDb db,
        AcademicYear year,
        SchoolClass cls,
        List<Student> kids,
      ) = await _seed();
      addTearDown(db.close);
      const String date = '2026-09-14';
      await db.upsertAttendance(
        yearId: year.id,
        classId: cls.id,
        studentId: kids[0].id,
        date: date,
        status: AttendanceStatus.late,
        source: AttendanceSource.manual,
        arrivalTime: '09:10',
      );
      expect(
        (await db.attendanceOf(kids[0].id, date))?.arrivalTime,
        '09:10',
      );
      await db.upsertAttendance(
        yearId: year.id,
        classId: cls.id,
        studentId: kids[0].id,
        date: date,
        status: AttendanceStatus.present,
        source: AttendanceSource.manual,
      );
      final AttendanceRow? r = await db.attendanceOf(kids[0].id, date);
      expect(r?.status, AttendanceStatus.present);
      expect(r?.arrivalTime, isNull);
    });
  });
}
