/// النسخة الاحتياطية تشمل كل الأعمدة (ومنها هاتف الطالب): تصدير
/// بالتسلسل العام ثم استرجاع كامل، ونسخ ما قبل الهاتف تُسترجع برقم فارغ.
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/backup_service.dart';
import 'package:student_hodor/data/db.dart';

Future<(AppDb, Student)> _seed({String? phone}) async {
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
  final int id = await db.addStudent(
    yearId: year,
    classId: cls,
    fullName: 'طالب النسخة',
    phone: phone,
  );
  final Student s = await (db.select(db.students)
        ..where((t) => t.id.equals(id)))
      .getSingle();
  return (db, s);
}

Future<Map<String, Object?>> _snapshotOf(AppDb db) async => <String, Object?>{
      'format': 'student-hodor-backup',
      'version': 1,
      'at': DateTime.now().toIso8601String(),
      'settings': await db.allSettings(),
      'years': <Map<String, Object?>>[
        for (final AcademicYear y in await db.select(db.academicYears).get())
          y.toJson(),
      ],
      'classes': <Map<String, Object?>>[
        for (final SchoolClass c in await db.select(db.schoolClasses).get())
          c.toJson(),
      ],
      'students': <Map<String, Object?>>[
        for (final Student s in await db.select(db.students).get()) s.toJson(),
      ],
    };

void main() {
  test('تسلسل الطالب يحمل الهاتف ذهاباً وإياباً', () async {
    final (AppDb db, Student s) = await _seed(phone: '07712345678');
    addTearDown(db.close);
    final Map<String, Object?> back =
        jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>;
    expect(Student.fromJson(back).phone, '07712345678');
  });

  test('الاسترجاع الكامل يعيد الهاتف', () async {
    final (AppDb db1, _) = await _seed(phone: '07712345678');
    addTearDown(db1.close);
    final AppDb db2 = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    await BackupService(db2).restoreFull(jsonEncode(await _snapshotOf(db1)));
    final Student s =
        await (db2.select(db2.students)).getSingle();
    expect(s.fullName, 'طالب النسخة');
    expect(s.phone, '07712345678');
  });

  test('نسخة قديمة بلا مفتاح الهاتف تُسترجع برقم فارغ', () async {
    final (AppDb db1, _) = await _seed(phone: '07712345678');
    addTearDown(db1.close);
    final Map<String, Object?> snap = await _snapshotOf(db1);
    final List<Map<String, Object?>> students =
        (snap['students']! as List<Map<String, Object?>>);
    students.first.remove('phone');
    final AppDb db2 = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    await BackupService(db2).restoreFull(jsonEncode(snap));
    final Student s =
        await (db2.select(db2.students)).getSingle();
    expect(s.phone, isNull);
  });
}
