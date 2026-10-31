/// جدول الحصص الدراسية: القوالب الافتراضية، تحليل الأوقات، واختيار الحصة.
///
/// لماذا ملف مستقل في `core`؟
/// - الأوقات وقواعد «الحصة الجارية» تُستهلك في المسح والإقفال والتقارير
///   والتصدير؛ تعريفها في مكان واحد يمنع أن يحسب كل موضع حصته بطريقته.
/// - لا يعتمد على قاعدة البيانات إطلاقاً: [LessonWindow] تمثيل خفيف تُبنى من
///   صف `Lesson` في طبقة البيانات، فتبقى القواعد قابلة للاختبار بلا قاعدة.
library;

import 'late_time.dart';

/// أسماء الحصص الافتراضية بالترتيب (تُستخدم إن لم يسمّها المستخدم).
class LessonLabels {
  const LessonLabels._();

  static const List<String> _names = <String>[
    'الحصة الأولى',
    'الحصة الثانية',
    'الحصة الثالثة',
    'الحصة الرابعة',
    'الحصة الخامسة',
    'الحصة السادسة',
    'الحصة السابعة',
    'الحصة الثامنة',
    'الحصة التاسعة',
    'الحصة العاشرة',
  ];

  /// اسم افتراضي لرقم حصة (1..N)؛ لما بعد العشرة «الحصة 11».
  static String of(int slot) =>
      slot >= 1 && slot <= _names.length ? _names[slot - 1] : 'الحصة $slot';
}

/// تعريف حصة في جدول المدرسة — قالب لا صف قاعدة بيانات.
class LessonTemplate {
  const LessonTemplate({
    required this.slot,
    required this.name,
    required this.start,
    required this.end,
  });

  final int slot;
  final String name;
  final String start;
  final String end;
}

/// نافذة حصة جاهزة للاستهلاك: المعرّف (للسجلات) + الرقم (للنطاقات) + الوقت.
class LessonWindow {
  const LessonWindow({
    required this.id,
    required this.slot,
    required this.name,
    required this.start,
    required this.end,
  });

  /// معرّف الحصة في قاعدة البيانات — ما تُخزّنه السجلات.
  final int id;

  /// رقم الحصة داخل اليوم (1..N) — ما تُخزّنه نطاقات الإجازات.
  final int slot;

  final String name;
  final String start;
  final String end;

  /// «08:00 — 08:45».
  String get timeLabel => '$start — $end';

  /// الاسم المعروض: اسم المستخدم إن وُجد، وإلا التسمية الافتراضية.
  String get displayName {
    final String n = name.trim();
    return n.isEmpty ? LessonLabels.of(slot) : n;
  }

  /// «الحصة الثالثة · 09:40 — 10:25».
  String get fullLabel => '$displayName · $timeLabel';

  int? get startMinutes => parseArrivalMinutes(start);

  int? get endMinutes => parseArrivalMinutes(end);

  /// هل يقع الوقت داخل نافذة الحصة (شاملاً بدايتها ونهايتها)؟
  bool containsTime(DateTime at) {
    final int? from = startMinutes;
    final int? to = endMinutes;
    if (from == null || to == null) {
      return false;
    }
    final int now = at.hour * 60 + at.minute;
    return now >= from && now <= to;
  }
}

/// وصف نطاق حصص الإجازة بالعربية — مصدر واحد للشاشة وملفات التصدير:
/// «كل الحصص»، «من الحصة 3 حتى آخر اليوم»، «الحصص 3–5».
String leaveScopeLabel({int? fromSlot, int? toSlot}) {
  if (fromSlot == null && toSlot == null) {
    return 'كل الحصص';
  }
  final int from = fromSlot ?? 1;
  if (toSlot == null) {
    return 'من ${LessonLabels.of(from)} حتى آخر اليوم';
  }
  if (from == toSlot) {
    return LessonLabels.of(from);
  }
  return 'الحصص $from–$toSlot';
}

/// قواعد جدول الحصص.
class LessonSchedule {
  const LessonSchedule._();

  /// العدد الافتراضي للحصص في المدرسة العراقية: ست حصص.
  static const int defaultCount = 6;

  /// جدول افتراضي متتابع بفواصل خمس دقائق — يُزرع مرة واحدة في قاعدة جديدة
  /// أو عند استعادة نسخة قديمة بلا جدول حصص.
  static const List<LessonTemplate> defaults = <LessonTemplate>[
    LessonTemplate(
      slot: 1,
      name: 'الحصة الأولى',
      start: '08:00',
      end: '08:45',
    ),
    LessonTemplate(
      slot: 2,
      name: 'الحصة الثانية',
      start: '08:50',
      end: '09:35',
    ),
    LessonTemplate(
      slot: 3,
      name: 'الحصة الثالثة',
      start: '09:40',
      end: '10:25',
    ),
    LessonTemplate(
      slot: 4,
      name: 'الحصة الرابعة',
      start: '10:30',
      end: '11:15',
    ),
    LessonTemplate(
      slot: 5,
      name: 'الحصة الخامسة',
      start: '11:20',
      end: '12:05',
    ),
    LessonTemplate(
      slot: 6,
      name: 'الحصة السادسة',
      start: '12:10',
      end: '12:55',
    ),
  ];

  /// ترتيب العرض: برقم الحصة ثم بالمعرّف (ثبات كامل عند تساوي الأرقام).
  static List<LessonWindow> sorted(Iterable<LessonWindow> windows) {
    final List<LessonWindow> out = windows.toList();
    out.sort((LessonWindow a, LessonWindow b) {
      final int bySlot = a.slot.compareTo(b.slot);
      return bySlot != 0 ? bySlot : a.id.compareTo(b.id);
    });
    return out;
  }

  /// الحصة الجارية الآن حسب أوقاتها.
  ///
  /// إن كان الوقت الحالي في فجوة بين حصتين اختيرت **الحصة التالية** (المعلم
  /// يبدأ التحضير قبل الجرس، والافتراض الأقرب للواقع أن الحصة القادمة هي
  /// المقصودة). خارج الدوام بالكامل: `null` — والقرار للمستخدم لا للتخمين.
  static LessonWindow? activeAt(List<LessonWindow> windows, DateTime at) {
    if (windows.isEmpty) {
      return null;
    }
    final List<LessonWindow> ordered = sorted(windows);
    for (final LessonWindow w in ordered) {
      if (w.containsTime(at)) {
        return w;
      }
    }
    final int now = at.hour * 60 + at.minute;
    for (final LessonWindow w in ordered) {
      final int? from = w.startMinutes;
      if (from != null && now < from) {
        return w;
      }
    }
    return null;
  }

  /// الحصة المقترحة عند فتح الشاشة: الجارية، ثم التالية، ثم **الأولى**
  /// (المسح الصباحي قبل الجرس يجب أن يفتح على الحصة الأولى لا على الأخيرة).
  static LessonWindow? suggested(List<LessonWindow> windows, DateTime at) {
    if (windows.isEmpty) {
      return null;
    }
    final LessonWindow? active = activeAt(windows, at);
    if (active != null) {
      return active;
    }
    final List<LessonWindow> ordered = sorted(windows);
    final int now = at.hour * 60 + at.minute;
    final int lastEnd = ordered.last.endMinutes ?? 0;
    // بعد نهاية آخر حصة: آخر حصة (تصحيح متأخر لليوم نفسه).
    if (now > lastEnd) {
      return ordered.last;
    }
    return ordered.first;
  }

  /// هل الأوقات صالحة ومتتابعة بلا تداخل؟ يُستخدم في محرر جدول الحصص.
  ///
  /// القاعدة: كل حصة تنتهي بعد بدايتها، ولا تبدأ حصة قبل نهاية سابقتها.
  /// تسمح بفجوة (استراحة) ولا تسمح بتداخل — التداخل يجعل «الحصة الجارية»
  /// غامضة ويُفسد حد التأخير.
  static String? validate(List<LessonWindow> windows) {
    if (windows.isEmpty) {
      return 'أضف حصة واحدة على الأقل';
    }
    final List<LessonWindow> ordered = sorted(windows);
    for (int i = 0; i < ordered.length; i++) {
      final LessonWindow w = ordered[i];
      final int? from = w.startMinutes;
      final int? to = w.endMinutes;
      if (from == null || to == null) {
        return 'وقت غير صالح في ${w.displayName} (استخدم صيغة HH:mm)';
      }
      if (to <= from) {
        return 'نهاية ${w.displayName} يجب أن تكون بعد بدايتها';
      }
      if (i > 0) {
        final int? prevEnd = ordered[i - 1].endMinutes;
        if (prevEnd != null && from < prevEnd) {
          return '${w.displayName} تتداخل مع ${ordered[i - 1].displayName}';
        }
      }
    }
    return null;
  }
}
