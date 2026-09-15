/// تقويم هجري (الخوارزمية الجدولية/الكويتية) بدون اعتماد خارجي.
/// عرض اختياري بجانب الميلادي؛ الدقة ±1 يوم عن الرؤية الشرعية وهو مقبول
/// للعرض غير الرسمي (موثق في دليل الاستخدام).
library;

class HijriDate {
  const HijriDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  static const List<String> monthNames = <String>[
    'محرم',
    'صفر',
    'ربيع الأول',
    'ربيع الآخر',
    'جمادى الأولى',
    'جمادى الآخرة',
    'رجب',
    'شعبان',
    'رمضان',
    'شوال',
    'ذو القعدة',
    'ذو الحجة',
  ];

  /// رقم يوم متسلسل في التقويم الهجري (للاختبارات والمقارنات).
  int get dayNumber => (year - 1) * 354 + (month - 1) * 29 + day;

  String get monthName => monthNames[month - 1];

  @override
  String toString() => '$day $monthName $year هـ';
}

class Hijri {
  const Hijri._();

  static int _gregorianToJdn(DateTime d) {
    final int y = d.year;
    final int m = d.month;
    final int day = d.day;
    final int a = (14 - m) ~/ 12;
    final int yy = y + 4800 - a;
    final int mm = m + 12 * a - 3;
    return day +
        ((153 * mm + 2) ~/ 5) +
        365 * yy +
        yy ~/ 4 -
        yy ~/ 100 +
        yy ~/ 400 -
        32045;
  }

  /// ميلادي → هجري جدولي.
  static HijriDate fromGregorian(DateTime d) {
    int l = _gregorianToJdn(d) - 1948440 + 10632;
    final int n = (l - 1) ~/ 10631;
    l = l - 10631 * n + 354;
    final int j = ((10985 - l) ~/ 5316) * ((50 * l) ~/ 17719) +
        (l ~/ 5670) * ((43 * l) ~/ 15238);
    l = l -
        ((30 - j) ~/ 15) * ((17719 * j) ~/ 50) -
        (j ~/ 16) * ((15238 * j) ~/ 43) +
        29;
    final int m = (24 * l) ~/ 709;
    final int day = l - (709 * m) ~/ 24;
    final int y = 30 * n + j - 30;
    return HijriDate(y, m, day);
  }
}
