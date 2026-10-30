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
