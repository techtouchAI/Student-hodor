/// سلامة المفاتيح الأجنبية (Phase 4) — أدلة صريحة لا افتراضات.
///
/// المبدأ: `PRAGMA foreign_keys` إعداد **خاص بكل اتصال**، و`foreign_key_check`
/// وحده لا يُثبت أن القيد كان مفعّلاً أثناء الكتابة. لذلك كل حالة هنا تتحقق من:
///  1. القيمة الفعلية لـ`PRAGMA foreign_keys` على الاتصال المستخدم،
///  2. خلوّ `PRAGMA foreign_key_check` من أي صف مخالف،
///  3. (حيث ينطبق) رفض SQLite الفعلي لإدخال سجل يتيم.
///
/// حالات أخرى لها ملفاتها الطبيعية: الهجرة 5⇒6 في `migration_v6_test.dart`،
/// والنسخ الاحتياطي والدمج في `backup_legacy_test.dart`.
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/years_service.dart';

/// قيمة PRAGMA رقمية من الاتصال نفسه.
Future<int> _pragma(AppDb db, String name) async {
  final QueryRow row = await db.customSelect('PRAGMA $name').getSingle();
  return row.data.values.first! as int;
}

/// الشرطان: التفعيل على هذا الاتصال، ولا صف يتيم.
Future<void> _expectFk(AppDb db, {required String after}) async {
  expect(
    await _pragma(db, 'foreign_keys'),
    1,
    reason: 'PRAGMA foreign_keys مفعّل على الاتصال الفعلي — $after',
  );
  expect(
    await db.customSelect('PRAGMA foreign_key_check').get(),
    isEmpty,
    reason: 'PRAGMA foreign_key_check بلا صفوف مخالفة — $after',
  );
}

/// سجل حضور يشير إلى طالب غير موجود (9999) — يجب أن ترفضه SQLite نفسها.
Future<void> _insertOrphan(AppDb db, {required int lessonId}) =>
    db.customStatement(
      'INSERT INTO attendance_rows '
      '(year_id, class_id, student_id, date, lesson_id, status, source) '
      "VALUES (1, 1, 9999, '2026-09-01', $lessonId, 0, 0)",
    );

Matcher get _fkRejected => throwsA(
      predicate(
        (Object e) => e.toString().toUpperCase().contains('FOREIGN KEY'),
        'خطأ مفتاح أجنبي من SQLite',
      ),
    );

/// سنة + صف + طالبان، ونظام حصص مزروع (من `onCreate`).
Future<({int yearId, int classId, int studentId})> _seed(AppDb db) async {
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
  final int studentId = await db.addStudent(
    yearId: yearId,
    classId: classId,
    fullName: 'طالب أول',
  );
  await db.addStudent(
    yearId: yearId,
    classId: classId,
    fullName: 'طالب ثانٍ',
  );
  return (yearId: yearId, classId: classId, studentId: studentId);
}

void main() {
  test('قاعدة جديدة: التفعيل فعّال والسجل اليتيم يُرفض فعلاً', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ({int yearId, int classId, int studentId}) seed = await _seed(db);
    await _expectFk(db, after: 'إنشاء قاعدة جديدة');

    // الحضور الصحيح مسموح…
    final int lessonId = (await db.firstLesson()).id;
    await db.upsertAttendance(
      yearId: seed.yearId,
      classId: seed.classId,
      studentId: seed.studentId,
      date: '2026-09-01',
      lessonId: lessonId,
      status: AttendanceStatus.present,
      source: AttendanceSource.manual,
    );
    expect(await db.select(db.attendanceRows).get(), hasLength(1));

    // …واليتيم مرفوض من SQLite نفسها (لا من طبقة التطبيق).
    await expectLater(
      _insertOrphan(db, lessonId: lessonId),
      _fkRejected,
      reason: 'القيد مُنفَّذ فعلياً أثناء الكتابة',
    );
    expect(
      await db.select(db.attendanceRows).get(),
      hasLength(1),
      reason: 'السجل المرفوض لم يُكتب',
    );
    await _expectFk(db, after: 'محاولة إدخال يتيم مرفوضة');
  });

  test('قاعدة موجودة تُفتح من جديد: التفعيل يُطبَّق على الاتصال الجديد', () async {
    final Directory dir = await Directory.systemTemp.createTemp('hodor_fk_');
    addTearDown(() async {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    });
    final File file = File('${dir.path}/school.sqlite');

    final AppDb first = AppDb.forTesting(NativeDatabase(file));
    final ({int yearId, int classId, int studentId}) seed = await _seed(first);
    final int lessonId = (await first.firstLesson()).id;
    await first.upsertAttendance(
      yearId: seed.yearId,
      classId: seed.classId,
      studentId: seed.studentId,
      date: '2026-09-02',
      lessonId: lessonId,
      status: AttendanceStatus.late,
      source: AttendanceSource.scan,
      arrivalTime: '08:10',
    );
    await first.close();

    // اتصال جديد على الملف نفسه: التفعيل يُعاد تنفيذه في `beforeOpen`.
    final AppDb again = AppDb.forTesting(NativeDatabase(file));
    addTearDown(again.close);
    await _expectFk(again, after: 'إعادة فتح قاعدة موجودة');
    expect(await again.select(again.attendanceRows).get(), hasLength(1));
    await expectLater(
      _insertOrphan(again, lessonId: lessonId),
      _fkRejected,
      reason: 'الاتصال الجديد يفرض القيد أيضاً',
    );
  });

  test('حذف سنة دراسية: لا صفوف يتيمة والسنة الأخرى سليمة', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int y1 = (await _seed(db)).yearId;
    final int y2 = await db.into(db.academicYears).insert(
          const AcademicYearsCompanion(
            name: Value('2027-2028'),
            start: Value('2027-09-01'),
            end: Value('2028-06-30'),
            active: Value(false),
          ),
        );
    final int class2 = await db.into(db.schoolClasses).insert(
          SchoolClassesCompanion(
            yearId: Value(y2),
            grade: const Value('الخامس'),
            section: const Value('ب'),
          ),
        );
    final int kid2 = await db.addStudent(
      yearId: y2,
      classId: class2,
      fullName: 'طالب السنة الثانية',
    );
    final int lessonId = (await db.firstLesson()).id;
    await db.upsertAttendance(
      yearId: y2,
      classId: class2,
      studentId: kid2,
      date: '2027-09-05',
      lessonId: lessonId,
      status: AttendanceStatus.present,
      source: AttendanceSource.manual,
    );

    await YearsService(db).deleteYear(y1, backup: () async => 'نسخة-قبل-الحذف');

    await _expectFk(db, after: 'حذف سنة دراسية');
    expect(await db.yearById(y2), isNotNull, reason: 'السنة الأخرى باقية');
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

  test('حذف صف: المحمي يُرفض بلا أثر، والفارغ يُحذف بسلامة', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ({int yearId, int classId, int studentId}) seed = await _seed(db);

    await expectLater(
      db.deleteClass(seed.classId),
      throwsA(isA<StateError>()),
      reason: 'الحماية الحالية: لا حذف صف فيه طلاب',
    );
    await _expectFk(db, after: 'محاولة حذف صف محمي مرفوضة');
    expect(await db.select(db.students).get(), hasLength(2));

    final int empty = await db.into(db.schoolClasses).insert(
          SchoolClassesCompanion(
            yearId: Value(seed.yearId),
            grade: const Value('السادس'),
            section: const Value('ج'),
          ),
        );
    await db.deleteClass(empty);
    expect(
      await (db.select(db.schoolClasses)..where((c) => c.id.equals(empty)))
          .get(),
      isEmpty,
    );
    await _expectFk(db, after: 'حذف صف فارغ');
  });

  test('ارتداد معاملة فاشلة: لا كتابة جزئية والسلامة قائمة', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ({int yearId, int classId, int studentId}) seed = await _seed(db);
    final int before = (await db.select(db.students).get()).length;

    await expectLater(
      db.transaction<void>(() async {
        // كتابة صحيحة ثم كتابة مرفوضة من SQLite ⇒ تُرتدّ المعاملة كاملة.
        await db.addStudent(
          yearId: seed.yearId,
          classId: seed.classId,
          fullName: 'طالب لن يُحفظ',
        );
        await _insertOrphan(db, lessonId: (await db.firstLesson()).id);
      }),
      _fkRejected,
    );

    expect(
      (await db.select(db.students).get()).length,
      before,
      reason: 'الطالب الذي كُتب قبل الخطأ ارتدّ أيضاً',
    );
    expect(await db.select(db.attendanceRows).get(), isEmpty);
    await _expectFk(db, after: 'ارتداد معاملة فاشلة');
  });
}
