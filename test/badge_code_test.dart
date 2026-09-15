import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/badge_code.dart';

void main() {
  test('رمز المدرسة حتمي لنفس الاسم ومختلف لاسم آخر', () {
    expect(BadgeCode.schoolCode('مدرسة النجاح'), BadgeCode.schoolCode('مدرسة النجاح'));
    expect(
      BadgeCode.schoolCode('مدرسة النجاح'),
      isNot(BadgeCode.schoolCode('مدرسة الفلاح')),
    );
  });

  test('دورة make/parse سليمة', () {
    final String code =
        BadgeCode.make(schoolName: 'مدرسة النجاح', sequence: 42, yearShort: 26);
    final ParsedBadgeCode? p = BadgeCode.parse(code);
    expect(p, isNotNull);
    expect(p!.sequence, 42);
    expect(p.yearShort, 26);
    expect(p.code, code);
  });

  test('رمز تالف يُرفض (checksum)', () {
    final String code =
        BadgeCode.make(schoolName: 'مدرسة النجاح', sequence: 7, yearShort: 26);
    final String corrupted =
        '${code.substring(0, code.length - 1)}${code.endsWith('A') ? 'B' : 'A'}';
    expect(BadgeCode.parse(corrupted), isNull);
  });

  test('نص عشوائي لا يُقبل', () {
    expect(BadgeCode.parse('hello world'), isNull);
    expect(BadgeCode.parse(''), isNull);
  });

  test('نسخة البدل الفاقد تُشفَّر وتُفك ولا تكسر الرموز القديمة', () {
    final String v1 =
        BadgeCode.make(schoolName: 'مدرسة النجاح', sequence: 42, yearShort: 26);
    final String v2 = BadgeCode.make(
      schoolName: 'مدرسة النجاح',
      sequence: 42,
      yearShort: 26,
      version: 2,
    );
    expect(v1, isNot(v2));
    expect(BadgeCode.parse(v1)?.version, 1);
    expect(BadgeCode.parse(v2)?.version, 2);
    expect(BadgeCode.parse(v2)?.sequence, 42);
  });
}
