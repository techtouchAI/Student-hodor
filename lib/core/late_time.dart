/// أدوات وقت الوصول الفعلي لسجلات التأخر: تنسيق وتحليل وحساب مدة التأخر.
///
/// الوقت يُخزَّن نصاً `HH:mm` في عمود `attendance_rows.arrival_time`؛ هذا
/// الملف مصدر الحقيقة الوحيد لقراءته وعرضه في الشاشات والتقارير كلها، فتتطابق
/// «فقرة التأخير» أينما ظهرت (كشف اليوم، ملف الطالب، المسح، التصدير).
library;

/// لحظة إلى نص الوقت المخزَّن `HH:mm` (نظام 24 ساعة).
String arrivalTimeString(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// يحلّ `HH:mm` إلى دقائق منذ منتصف الليل؛ `null` إن كانت الصيغة غير صالحة.
int? parseArrivalMinutes(String? hhmm) {
  if (hhmm == null) {
    return null;
  }
  final List<String> parts = hhmm.split(':');
  if (parts.length != 2) {
    return null;
  }
  final int? h = int.tryParse(parts[0]);
  final int? m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
    return null;
  }
  return h * 60 + m;
}

/// دقائق بداية اليوم الدراسي من الإعداد `HH:mm` (الافتراضي 08:00 عند الخطأ).
int dayStartMinutes(String? setting) => parseArrivalMinutes(setting) ?? 8 * 60;

/// مدة التأخر: الوصول − بداية الدوام الرسمية؛ صفر إن وصل قبلها أو بلا وقت.
Duration latenessDuration({required String? arrivalTime, String? dayStart}) {
  final int? arrival = parseArrivalMinutes(arrivalTime);
  if (arrival == null) {
    return Duration.zero;
  }
  final int diff = arrival - dayStartMinutes(dayStart);
  return diff <= 0 ? Duration.zero : Duration(minutes: diff);
}

/// وصف عربي لمدة التأخر: «25 دقيقة» / «ساعة» / «ساعتان و5 دقائق».
/// نص فارغ عندما لا مدة (وصول قبل الدوام أو بلا وقت).
String lateDurationLabel(Duration d) {
  final int total = d.inMinutes;
  if (total <= 0) {
    return '';
  }
  final int h = total ~/ 60;
  final int m = total % 60;
  if (h == 0) {
    return '$m دقيقة';
  }
  final String hours = switch (h) {
    1 => 'ساعة',
    2 => 'ساعتان',
    _ => '$h ساعات',
  };
  return m == 0 ? hours : '$hours و$m دقيقة';
}

/// سطر عرض سجل التأخر الكامل:
/// «متأخر — الساعة 08:23 (تأخير 23 دقيقة)».
/// بلا بداية دوام معروفة: «متأخر — الساعة 08:23».
/// بلا وقت محفوظ (سجل يدوي قديم): «متأخر» وحدها.
String lateInfoLabel({required String? arrivalTime, String? dayStart}) {
  final String? t = arrivalTime;
  if (parseArrivalMinutes(t) == null) {
    return 'متأخر';
  }
  final String dur = lateDurationLabel(
    latenessDuration(arrivalTime: t, dayStart: dayStart),
  );
  return dur.isEmpty ? 'متأخر — الساعة $t' : 'متأخر — الساعة $t (تأخير $dur)';
}
