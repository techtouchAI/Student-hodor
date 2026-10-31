/// تسميات وألوان حالات الحضور — مصدر حقيقة واحد لكل الشاشات والتقارير.
///
/// كانت هذه الدوال معرّفة داخل `reports_screen.dart` وتستوردها ملفات أخرى
/// (اعتماد معكوس)؛ نُقلت هنا لتُستخدم من كشف اليوم والشبكات والملفات المصدّرة.
library;

import 'package:flutter/material.dart';

import '../data/db.dart';
import 'lesson.dart';

/// اسم الحالة بالعربية؛ `null` تعني «لم يُسجَّل بعد».
String statusName(int? status) {
  switch (status) {
    case AttendanceStatus.present:
      return 'حاضر';
    case AttendanceStatus.absent:
      return 'غائب';
    case AttendanceStatus.leave:
      return 'إجازة';
    case AttendanceStatus.late:
      return 'متأخر';
    default:
      return '—';
  }
}

/// لون الحالة المطابق لمواصفة التصدير (أخضر/أحمر/أصفر/برتقالي).
Color statusColor(int? status) {
  switch (status) {
    case AttendanceStatus.present:
      return Colors.green;
    case AttendanceStatus.absent:
      return Colors.red;
    case AttendanceStatus.leave:
      return Colors.amber;
    case AttendanceStatus.late:
      return Colors.orange;
    default:
      return Colors.grey;
  }
}

/// حرف واحد يوضع داخل_avatar القوائم.
String statusLetter(int? status) => statusName(status).characters.first;

/// ألوان الحالات بست عشري — مصدر واحد للإكسل وPDF ومفتاح الرموز.
///
/// أُضيف [absentPartial] لأن «غياب حصة» ليس «غياب يوم»: الدرجة الباهتة تمنع
/// قراءة الغياب الجزئي غياباً كاملاً مع بقاء عائلة اللون نفسها في المفتاح.
class StatusHex {
  const StatusHex._();
  static const String present = '#C6EFCE';
  static const String absent = '#FFC7CE';
  static const String absentPartial = '#FBE0E3';
  static const String leave = '#FFEB9C';
  static const String late = '#FCD5B4';
  static const String offDay = '#D9D9D9';
  static const String header = '#0D6E5F';

  /// `'#RRGGBB'` ⇒ `0xFFRRGGBB` (لصيغة PDF التي تأخذ عدداً).
  static int asInt(String hex) =>
      int.parse('FF${hex.substring(1)}', radix: 16);
}

/// لون خلية اليوم في شاشة الشهر: باهت عند الغياب الجزئي، أحمر عند الكامل.
const Color partialAbsentColor = Color(0xFFF6C6CB);

/// عدد الحصص بالعربية: «حصة واحدة»، «حصتان»، «٣ حصص»، «١١ حصة».
String arabicLessonCount(int n) {
  if (n == 1) {
    return 'حصة واحدة';
  }
  if (n == 2) {
    return 'حصتان';
  }
  if (n >= 3 && n <= 10) {
    return '$n حصص';
  }
  return '$n حصة';
}

/// نوع الغياب في يوم: لا غياب / جزئي / كامل.
enum DayAbsence { none, partial, full }

/// وصف دقيق ليوم واحد: الحالة المجمّعة + عدد حصص الغياب مقابل عدد الحصص.
///
/// الغرض: منع أن يُقرأ «غياب حصة واحدة» غياباً ليوم كامل في أي مخرج (شاشة،
/// إكسل، PDF) — والعدّاد القانوني `absentDays` يبقى كما هو (أيام).
class DayPresence {
  const DayPresence({
    required this.status,
    required this.absentLessons,
    required this.totalLessons,
    required this.recordedLessons,
  });

  /// الحالة المجمّعة من [ReportsService.aggregateStatus] (قبل التسمية).
  final int? status;

  /// عدد الحصص التي غاب فيها الطالب هذا اليوم.
  final int absentLessons;

  /// عدد حصص الجدول كله (أساس «كامل»).
  final int totalLessons;

  /// عدد الحصص المسجَّلة فعلاً في اليوم.
  final int recordedLessons;

  bool get hasData => recordedLessons > 0;

  DayAbsence get absence {
    if (absentLessons <= 0) {
      return DayAbsence.none;
    }
    // «كامل» = غاب عن **كل** حصص الجدول، أو عن كل ما سُجِّل يومها إن كانت
    // الحصص المسجّلة تغطي اليوم كله. غير ذلك جزئي.
    if (totalLessons > 0 && absentLessons >= totalLessons) {
      return DayAbsence.full;
    }
    if (totalLessons <= 0 && absentLessons == recordedLessons) {
      return DayAbsence.full;
    }
    return DayAbsence.partial;
  }

  bool get isPartial => absence == DayAbsence.partial;

  /// النص المعروض للحالة اليومية — لا يقول «غائب» إلا إذا كان الغياب كاملاً.
  String get label {
    if (!hasData) {
      // النص التاريخي نفسه الذي يظهر في ملفات التصدير حين لا سجل لليوم.
      return status == null ? 'لم يسجل' : statusName(status);
    }
    switch (absence) {
      case DayAbsence.full:
        return 'غياب كامل';
      case DayAbsence.partial:
        return 'غياب جزئي — غاب عن ${arabicLessonCount(absentLessons)}';
      case DayAbsence.none:
        return statusName(status);
    }
  }
}

/// لون خلية اليوم في شبكة الشهر: باهت للغياب الجزئي، وأحمر للكامل.
Color dayStatusColor({
  required int? status,
  required Map<int, int> lessonStatuses,
  required int totalLessons,
}) {
  final DayPresence day = describeDay(
    status: status,
    lessonStatuses: lessonStatuses,
    totalLessons: totalLessons,
  );
  return day.isPartial ? partialAbsentColor : statusColor(status);
}

/// يبني وصف اليوم من خريطة حالات حصصه (lessonId ⇒ status) وعدد حصص الجدول.
DayPresence describeDay({
  required int? status,
  required Map<int, int> lessonStatuses,
  required int totalLessons,
}) {
  int absent = 0;
  for (final int st in lessonStatuses.values) {
    if (st == AttendanceStatus.absent) {
      absent++;
    }
  }
  return DayPresence(
    status: status,
    absentLessons: absent,
    totalLessons: totalLessons,
    recordedLessons: lessonStatuses.length,
  );
}

/// وصف حالة اليوم في كشف اليوم (يشمل «لم يُسجَّل»).
String statusHint(int? status) => status == null ? 'لم يُسجَّل بعد' : statusName(status);

/// سطر حالات الحصص في يوم واحد — للعرض في التلميحات وقوائم الطالب:
/// «الأولى: حاضر • الثانية: غائب • الثالثة: —».
///
/// المصدر هو خريطة الحالات (lessonId ⇒ status) التي يبنيها
/// [ReportsService.summarizeDay]؛ الحصص التي لم تُسجَّل تظهر «—» صراحةً بدل
/// حذفها، لأن غياب السطر يعني معلومة ناقصة لا حضوراً.
String lessonBreakdownText(
  List<LessonWindow> lessons,
  Map<int, int> statuses,
) {
  if (lessons.isEmpty) {
    return '';
  }
  return lessons
      .map((LessonWindow l) => '${l.displayName}: ${statusName(statuses[l.id])}')
      .join(' • ');
}

/// حروف الحصص المضغوطة بترتيب الجدول: «ح·غ·—·ح».
///
/// تُستخدم في الأماكن الضيقة (خلية شبكة الشهر) حيث لا يتسع الاسم الكامل.
String lessonCompactMarks(
  List<LessonWindow> lessons,
  Map<int, int> statuses,
) {
  if (lessons.isEmpty) {
    return '';
  }
  return lessons
      .map(
        (LessonWindow l) => statuses[l.id] == null
            ? '—'
            : statusLetter(statuses[l.id]),
      )
      .join('·');
}
