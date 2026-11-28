import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';

/// اختبار الترقية الحقيقية: قاعدة **إصدار 6** على القرص تُفتح بتطبيق
/// الإصدار 7 (مهمات الإقفال التلقائي) — الجدول الجديد يُنشأ فارغاً،
/// وبقية البيانات تبقى بلا أثر.
///
/// الطريقة: تُنشأ قاعدة 7 بمخطط Drift نفسه، ثم يُسقط جدول `closure_tasks`
/// ويُضبط `user_version = 6`، فتُفتح من جديد فتعمل الهجرة فعلياً.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hodor_mig7_');
  });

  tearDown(() async {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  test('ترقية 6⇒7 تُنشئ جدول المهمات فارغاً وتُبقي البيانات', () async {
    final File file = File('${dir.path}/school_v6.sqlite');

    // ---------- (1) قاعدة إصدار 6 (الجدول الجديد غير موجود) ----------
    final AppDb v6 = AppDb.forTesting(NativeDatabase(file));
    addTearDown(v6.close);
    final int year = await v6.into(v6.academicYears).insert(
          const AcademicYearsCompanion(
            name: Value('2026-2027'),
            start: Value('2026-09-01'),
            end: Value('2027-06-30'),
            active: Value(true),
          ),
        );
    final int cls = await v6.into(v6.schoolClasses).insert(
      SchoolClassesCompanion(
        yearId: Value(year),
        grade: const Value('السادس'),
        section: const Value('أ'),
      ),
    );
    final int student = await v6.into(v6.students).insert(
      StudentsCompanion(
        yearId: Value(year),
        classId: Value(cls),
        fullName: const Value('طالب'),
        personKey: const Value('p1'),
        seq: const Value(1),
        createdAt: const Value('2026-09-01T08:00:00'),
      ),
    );
    await v6.customStatement('DROP TABLE closure_tasks');
    await v6.customStatement('PRAGMA user_version = 6');
    await v6.close();

    // ---------- (2) الفتح بتطبيق الإصدار 7 ----------
    final AppDb db = AppDb.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 7);

    final List<QueryRow> tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'closure_tasks'",
        )
        .get();
    expect(tables, hasLength(1), reason: 'الجدول الجديد أُنشئ');

    expect(await db.select(db.closureTasks).get(), isEmpty,
        reason: 'الهجرة لا تزرع مهام — الجدولة تُبنى عند التشغيل',);

    // ---------- (3) البيانات القديمة تبقى ----------
    expect((await db.select(db.students).get()).single.id, student);
    expect((await db.select(db.schoolClasses).get()).single.id, cls);
    final List<QueryRow> fkViolations =
        await db.customSelect('PRAGMA foreign_key_check').get();
    expect(fkViolations, isEmpty);

    // ---------- (4) الجدول قابل للاستخدام بعد الهجرة ----------
    final Lesson lesson = await db.firstLesson();
    await db.upsertClosureTask(
      yearId: year,
      classId: cls,
      date: '2026-09-16',
      lessonId: lesson.id,
      targetAt: '2026-09-16T08:45:00',
    );
    final ClosureTask? t = await db.closureTaskOf(cls, '2026-09-16', lesson.id);
    expect(t, isNotNull);
    expect(t?.targetAt, '2026-09-16T08:45:00');

    final List<QueryRow> indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name IN ('idx_closure_due', 'idx_closure_class_date')",
        )
        .get();
    expect(
      indexes.map((QueryRow r) => r.read<String>('name')).toSet(),
      <String>{'idx_closure_due', 'idx_closure_class_date'},
    );
  });

  test('قاعدة جديدة تكتب الإصدار 7 من أول فتح', () async {
    final File file = File('${dir.path}/fresh.sqlite');
    final AppDb db = AppDb.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 7);
  });
}
