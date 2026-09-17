/// رقم هاتف الطالب الاختياري: حفظ واسترجاع + سطر الباج الدائم
/// (الرقم أو فراغ 11 رقماً).
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/features/badges/badge_spec.dart';

void main() {
  test('الهاتف الاختياري يُحفظ ويُسترجع', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
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
    final int withPhone = await db.addStudent(
      yearId: year,
      classId: cls,
      fullName: 'بهاتف',
      phone: '07712345678',
    );
    final int withoutPhone = await db.addStudent(
      yearId: year,
      classId: cls,
      fullName: 'بلا هاتف',
    );
    final Student a = await (db.select(db.students)
          ..where((s) => s.id.equals(withPhone)))
        .getSingle();
    final Student b = await (db.select(db.students)
          ..where((s) => s.id.equals(withoutPhone)))
        .getSingle();
    expect(a.phone, '07712345678');
    expect(b.phone, isNull);
  });

  test('سطر هاتف الباج: الرقم أو فراغ 11 رقماً', () {
    BadgeSpec spec(String? phone) => BadgeSpec(
          schoolName: 'م',
          directorName: 'د',
          studentName: 'ط',
          grade: 'الأول',
          section: 'أ',
          yearName: '2026-2027',
          code: 'X',
          sequence: 1,
          phone: phone,
        );
    expect(spec('07712345678').phoneLine, 'الهاتف: 07712345678');
    expect(spec(null).phoneLine, 'الهاتف: ${'_' * 11}');
    expect(spec('').phoneLine, 'الهاتف: ${'_' * 11}');
  });
}
