import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/hijri.dart';
import 'package:student_hodor/core/school_time.dart';

void main() {
  test('نطاقات سليمة لسنة كاملة', () {
    DateTime d = DateTime(2026, 1, 1);
    for (int i = 0; i < 365; i++) {
      final HijriDate h = Hijri.fromGregorian(d);
      expect(h.month, inInclusiveRange(1, 12));
      expect(h.day, inInclusiveRange(1, 30));
      expect(h.year, inInclusiveRange(1447, 1448));
      d = d.add(const Duration(days: 1));
    }
  });

  test('تسلسل الأيام متصل (لا قفزات)', () {
    DateTime d = DateTime(2026, 3, 1);
    int prev = Hijri.fromGregorian(d).dayNumber;
    for (int i = 1; i < 360; i++) {
      d = d.add(const Duration(days: 1));
      final int cur = Hijri.fromGregorian(d).dayNumber;
      expect(cur - prev, 1, reason: 'at $d');
      prev = cur;
    }
  });

  test('نص العرض يحتوي اسم شهر هجري', () {
    expect(SchoolTime.hijriString(DateTime(2026, 9, 15)), contains('هـ'));
  });
}
