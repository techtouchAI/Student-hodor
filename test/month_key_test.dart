import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/school_time.dart';
import 'package:student_hodor/features/export/excel_builder.dart';

void main() {
  test('monthsBetweenKeys يحل السنة الميلادية الصحيحة لأشهر عابرة', () {
    final List<MonthKey> ms =
        SchoolTime.monthsBetweenKeys('2025-09-01', '2026-06-30');
    expect(ms.length, 10);
    expect(ms.first, const MonthKey(2025, 9));
    expect(ms.last, const MonthKey(2026, 6));
    expect(ms[4], const MonthKey(2026, 1));
    expect(ms[4].key, '2026-01');
  });

  test('isValidDay يميز أشهر 30/31 يوماً وشباط', () {
    const MonthKey jan = MonthKey(2026, 1);
    const MonthKey feb = MonthKey(2026, 2);
    const MonthKey apr = MonthKey(2026, 4);
    expect(jan.isValidDay(31), isTrue);
    expect(apr.isValidDay(31), isFalse);
    expect(feb.isValidDay(28), isTrue);
    expect(feb.isValidDay(30), isFalse);
  });

  test('sanitizeSheetName: بلا محارف ممنوعة وبقص آمن', () {
    expect(
      ExcelBuilder.sanitizeSheetName('السادس-أ-آذار').length,
      lessThanOrEqualTo(31),
    );
    expect(ExcelBuilder.sanitizeSheetName('a/b?c*d[e]f:g'), 'a-b-c-d-e-f-g');
    expect(ExcelBuilder.sanitizeSheetName(''), 'sheet');
    expect(ExcelBuilder.sanitizeSheetName('x' * 40).length, 27);
    // القص على أسماء عربية لا يرمي (كان substring(0,30) يرمي RangeError).
    expect(() => ExcelBuilder.sanitizeSheetName('السادس-أ-آذار'), returnsNormally);
  });
}
