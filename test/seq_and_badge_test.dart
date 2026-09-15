import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/badge_code.dart';
import 'package:student_hodor/data/db.dart';

Future<int> _seedYear(AppDb db) async {
  await db.setSetting('school_name', 'مدرسة النجاح');
  return db.into(db.academicYears).insert(
        const AcademicYearsCompanion(
          name: Value('2026-2027'),
          start: Value('2026-09-01'),
          end: Value('2027-06-30'),
          active: Value(true),
        ),
      );
}

void main() {
  test('تسلسل السنة فريد عبر صفين ورموز البادجات لا تتصادم', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int y = await _seedYear(db);
    final int a = await db.into(db.schoolClasses).insert(
          SchoolClassesCompanion(
            yearId: Value(y),
            grade: const Value('السادس'),
            section: const Value('أ'),
          ),
        );
    final int b = await db.into(db.schoolClasses).insert(
          SchoolClassesCompanion(
            yearId: Value(y),
            grade: const Value('السادس'),
            section: const Value('ب'),
          ),
        );
    for (int i = 0; i < 3; i++) {
      await db.addStudent(yearId: y, classId: a, fullName: 'طالب أ$i');
      await db.addStudent(yearId: y, classId: b, fullName: 'طالب ب$i');
    }
    final List<Student> all = await db.select(db.students).get();
    expect(all.length, 6);
    final Set<int> seqs = <int>{for (final Student s in all) s.seq};
    expect(seqs.length, 6, reason: 'التسلسل يجب ألا يتكرر داخل السنة');
    final List<Badge> badges = await db.select(db.badges).get();
    final Set<String> codes = <String>{for (final Badge x in badges) x.code};
    expect(codes.length, 6, reason: 'رموز البادجات يجب ألا تتصادم');
    for (final String code in codes) {
      expect(BadgeCode.parse(code), isNotNull);
    }
  });

  test('بدل فاقد: إبطال القديم وإصدار رمز مختلف صالح للقراءة', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final int y = await _seedYear(db);
    final int c = await db.into(db.schoolClasses).insert(
          SchoolClassesCompanion(
            yearId: Value(y),
            grade: const Value('الأول'),
            section: const Value('أ'),
          ),
        );
    final int id = await db.addStudent(yearId: y, classId: c, fullName: 'علي حسن');
    final Badge? firstMaybe = await db.activeBadgeOf(id);
    expect(firstMaybe, isNotNull);
    final Badge first = firstMaybe!;
    final Badge? secondMaybe = await db.reissueBadge(id);
    expect(secondMaybe, isNotNull);
    final Badge second = secondMaybe!;
    expect(second.code, isNot(first.code));
    expect(second.version, 2);
    expect(BadgeCode.parse(second.code)?.version, 2);
    expect((await db.activeBadgeOf(id))?.id, second.id);
    final Badge old =
        await (db.select(db.badges)..where((x) => x.id.equals(first.id)))
            .getSingle();
    expect(old.status, 1);
    // الرمز القديم يبقى صالح الصيغة لكنه مبطل في القاعدة.
    expect(BadgeCode.parse(first.code), isNotNull);
  });
}
