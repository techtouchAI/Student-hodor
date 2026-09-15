/// أدوات التقويم المدرسي: أيام الدوام، العطل، الأشهر العربية، الهجري.
library;

import 'hijri.dart';

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

  /// مفاتيح أشهر (سنة، شهر) بين تاريخين شاملين — تحل السنة الميلادية الصحيحة
  /// لكل شهر داخل امتداد سنة دراسية عابرة للسنتين (أيلول 2025 … حزيران 2026).
  static List<MonthKey> monthsBetween(DateTime from, DateTime to) {
    final List<MonthKey> out = <MonthKey>[];
    DateTime d = DateTime(from.year, from.month);
    final DateTime end = DateTime(to.year, to.month);
    while (!d.isAfter(end)) {
      out.add(MonthKey(d.year, d.month));
      d = DateTime(d.year, d.month + 1);
    }
    return out;
  }

  /// امتداد الأشهر بين مفتاحي بداية/نهاية (نص ISO).
  static List<MonthKey> monthsBetweenKeys(String startKey, String endKey) =>
      monthsBetween(parseKey(startKey), parseKey(endKey));

  static String formatFullAr(DateTime d, {bool withHijri = false}) {
    final String g =
        '${weekdayNames[d.weekday - 1]} ${d.day} ${monthNames[d.month - 1]} ${d.year}';
    if (!withHijri) {
      return g;
    }
    return '$g ـ ${hijriString(d)}';
  }

  /// تاريخ هجري جدولي للعرض، أو نص فارغ عند أي تعذر.
  static String hijriString(DateTime d) {
    try {
      final HijriDate h = Hijri.fromGregorian(d);
      if (h.month < 1 || h.month > 12 || h.day < 1 || h.day > 30) {
        return '';
      }
      return '${h.day} ${h.monthName} ${h.year} هـ';
    } catch (_) {
      return '';
    }
  }
}

/// مفتاح شهر ميلادي صريح (سنة + شهر) — مصدر الحقيقة لأشهر التصدير والتقارير،
/// يمنع افتراض أن كل أشهر السنة الدراسية تقع في سنة بداية السنة الدراسية.
class MonthKey {
  const MonthKey(this.year, this.month);

  final int year;
  final int month;

  DateTime get first => DateTime(year, month, 1);

  DateTime get last => DateTime(year, month + 1, 0);

  /// مفتاح نصي ثابت للمقارنة والمفاتيح (yyyy-MM).
  String get key => '${year.toString().padLeft(4, '0')}'
      '-${month.toString().padLeft(2, '0')}';

  String get label => '${SchoolTime.monthNames[month - 1]} $year';

  bool isValidDay(int day) => DateTime(year, month, day).month == month;

  @override
  bool operator ==(Object other) =>
      other is MonthKey && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  String toString() => key;
}
