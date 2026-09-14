/// أدوات التقويم المدرسي: أيام الدوام، العطل، الأشهر العربية، الهجري.
library;

import 'package:hijri_converter/hijri_converter.dart';

class SchoolTime {
  const SchoolTime._();

  /// أسماء أيام الأسبوع مرتبة حسب DateTime.weekday (1=الاثنين .. 7=الأحد).
  static const List<String> weekdayNames = <String>[
    'الاثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
    'الأحد',
  ];

  static const List<String> monthNames = <String>[
    'كانون الثاني',
    'شباط',
    'آذار',
    'نيسان',
    'أيار',
    'حزيران',
    'تموز',
    'آب',
    'أيلول',
    'تشرين الأول',
    'تشرين الثاني',
    'كانون الأول',
  ];

  /// أيام الدوام الافتراضية في العراق: الأحد–الخميس.
  static const Set<int> defaultWorkWeekdays = <int>{7, 1, 2, 3, 4};

  static String dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime parseKey(String key) {
    final List<String> p = key.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  static bool isSchoolDay(
    DateTime day, {
    required Set<int> workWeekdays,
    required Set<String> holidayKeys,
  }) =>
      workWeekdays.contains(day.weekday) && !holidayKeys.contains(dateKey(day));

  /// كل مفاتيح التواريخ بين تاريخين (شاملين).
  static List<String> keysBetween(DateTime from, DateTime to) {
    final List<String> out = <String>[];
    DateTime d = DateTime(from.year, from.month, from.day);
    final DateTime end = DateTime(to.year, to.month, to.day);
    while (!d.isAfter(end)) {
      out.add(dateKey(d));
      d = d.add(const Duration(days: 1));
    }
    return out;
  }

  static String formatFullAr(DateTime d, {bool withHijri = false}) {
    final String g =
        '${weekdayNames[d.weekday - 1]} ${d.day} ${monthNames[d.month - 1]} ${d.year}';
    if (!withHijri) {
      return g;
    }
    return '$g ـ ${hijriString(d)}';
  }

  /// تاريخ هجري (أم القرى) أو نص فارغ عند أي تعذر.
  static String hijriString(DateTime d) {
    try {
      final HijriDate h = HijriConverter.gregorianToHijri(d);
      return '${h.day}/${h.month}/${h.year} هـ';
    } catch (_) {
      return '';
    }
  }
}
