/// حذف سنة دراسية واحدة بنطاقها الكامل: يزيل صفوفها وطلابها وبادجاتهم
/// وحضورها وإجازاتها وجلساتها وأحداث مسحها — ويُبقى السنوات الأخرى سالمة،
/// ويعيد مسار النسخة الاحتياطية الإجبارية التي تُنشأ قبل الحذف.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/years_service.dart';

/// سنة دراسية كاملة البيانات: صف + طالب (وباجه) + جلسة + حضور + إجازة
/// + حدث مسح. [yearName] يميز السنتين في القاعدة نفسها.
Future<int> _seedYear(AppDb db, String yearName, String start) async {
  final int yearId = await db.into(db.academicYears).insert(
        AcademicYearsCompanion(
          name: Value(yearName),
          start: Value(start),
          end: Value('${int.parse(start.substring(0, 4)) + 1}-06-30'),
          active: const Value(false),
        ),
      );
  final int classId = await db.into(db.schoolClasses).insert(
        SchoolClassesCompanion(
          yearId: Value(yearId),
          grade: const Value('السادس'),
          section: Value(yearName.substring(2, 3)),
        ),
      );
  final int studentId = await db.addStudent(
    yearId: yearId,
    classId: classId,
    fullName: 'طالب $yearName',
  );
  const String date = '2026-09-13';
  final int sessionId = await db.into(db.sessions).insert(
        SessionsCompanion(
          yearId: Value(yearId),
          classId: Value(classId),
          date: const Value(date),
          openedAt: const Value('2026-09-13T07:30:00'),
        ),
      );
  await db.into(db.scanEvents).insert(
        ScanEventsCompanion(
          sessionId: Value(sessionId),
          code: const Value('SH-XXX-0001-26-K7'),
          studentId: Value(studentId),
          result: const Value(ScanResult.ok),
          at: const Value('2026-09-13T07:40:00'),
        ),
      );
  await db.upsertAttendance(
    yearId: yearId,
    classId: classId,
    studentId: studentId,
    date: date,
    status: AttendanceStatus.present,
    source: AttendanceSource.scan,
    sessionId: sessionId,
    arrivalTime: '07:40',
  );
  await db.into(db.leaves).insert(
        LeavesCompanion(
          yearId: Value(yearId),
          studentId: Value(studentId),
          start: const Value('2026-09-20'),
          end: const Value('2026-09-21'),
          type: const Value(0),
          createdAt: const Value('2026-09-19T10:00:00'),
        ),
      );
  return yearId;
}

Future<int> _count(AppDb db, String table) async {
  final List<QueryRow> rows =
      await db.customSelect('SELECT COUNT(*) AS c FROM $table').get();
  return rows.single.read<int>('c');
}

void main() {
  test('حذف سنة يزيل كل ما يخصها وحدها ويُبقى السنة الأخرى سالمة', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int y1 = await _seedYear(db, '2026-2027', '2026-09-01');
    final int y2 = await _seedYear(db, '2027-2028', '2027-09-01');
    expect(await _count(db, 'academic_years'), 2);
    expect(await _count(db, 'students'), 2);

    final String backup =
        await YearsService(db).deleteYear(y1, backup: () async => 'نسخة-قبل-الحذف');
    expect(backup, 'نسخة-قبل-الحذف');

    // السنة المحذوفة اختفت بكل توابعها.
    expect(await db.yearById(y1), isNull);
    expect(
      await (db.select(db.schoolClasses)..where((c) => c.yearId.equals(y1)))
          .get(),
      isEmpty,
    );
    expect(
      await (db.select(db.students)..where((s) => s.yearId.equals(y1))).get(),
      isEmpty,
    );
    expect(
      await (db.select(db.attendanceRows)..where((a) => a.yearId.equals(y1)))
          .get(),
      isEmpty,
    );
    expect(
      await (db.select(db.leaves)..where((l) => l.yearId.equals(y1))).get(),
      isEmpty,
    );
    expect(
      await (db.select(db.sessions)..where((s) => s.yearId.equals(y1))).get(),
      isEmpty,
    );
    expect(
      await _count(db, 'scan_events'),
      1,
      reason: 'حدث مسح السنة المحذوفة يُنظف ويبقى حدث السنة الأخرى',
    );

    // بادجات طلاب السنة المحذوفة اختفت وباج السنة الأخرى باقٍ.
    expect(await _count(db, 'badges'), 1);

    // السنة الثانية بكل بياناتها لم تُمس.
    expect(await db.yearById(y2), isNotNull);
    expect(await _count(db, 'academic_years'), 1);
    expect(
      await (db.select(db.students)..where((s) => s.yearId.equals(y2))).get(),
      hasLength(1),
    );
    expect(
      await (db.select(db.attendanceRows)..where((a) => a.yearId.equals(y2)))
          .get(),
      hasLength(1),
    );
  });

  test('حذف آخر سنة يفرغ القاعدة بالكامل بلا استثناء', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int y1 = await _seedYear(db, '2026-2027', '2026-09-01');
    await YearsService(db).deleteYear(y1, backup: () async => 'b1');
    expect(await _count(db, 'academic_years'), 0);
    expect(await _count(db, 'students'), 0);
    expect(await _count(db, 'badges'), 0);
    expect(await _count(db, 'sessions'), 0);
    expect(await _count(db, 'scan_events'), 0);
    expect(await _count(db, 'attendance_rows'), 0);
    expect(await _count(db, 'leaves'), 0);
    // الحذف مُدقَّق في سجل المراجعة.
    final List<AuditLog> logs = await db.select(db.auditLogs).get();
    expect(
      logs.any((AuditLog l) => l.action == 'year_delete'),
      isTrue,
    );
  });
}
