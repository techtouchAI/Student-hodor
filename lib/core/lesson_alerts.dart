/// تنبيه بداية/نهاية الحصة: إشعار مرئي (وصوتي عند التفعيل) عند بلوغ وقت
/// بداية كل حصة ونهايتها.
///
/// الآلية تتبع منظومة الإشعارات القائمة (نفس طبقة [LocalNotifications]
/// وقناتها): في كل دورة زمنية يُفحص **جدول الحصص الفعلي** لليوم، ويُعرض
/// التنبيه مرة واحدة لكل (تاريخ، حصة، لحظة بداية/نهاية). حالة «تم التنبيه»
/// تُخزَّن في إعداد [_shownKey] بتنسيق `date:slot:kind` مفصول بفواصل، مع
/// تنظيف القيم القديمة (ما قبل اليوم) في كل دورة — تبقى القيم منحصرةً في
/// يوم واحد فلا تتراكم.
///
/// التفعيل والتحكم بالصوت من إعدادات «جدول الحصص»:
/// - `lesson_alerts_enabled`: التنبيهات المرئية (أساسي، مفعّل افتراضيًا).
/// - `lesson_alerts_sound`: الصوت (جرس المدرسة، مفعّل افتراضيًا).
///
/// لا يُنفّذ التنبيه في يوم عطلة أو غير دوام (نفس قاعدة جدولة الإقفال —
/// [ClosureScheduler.isSchoolDay]).
library;

import '../core/late_time.dart';
import '../core/local_notifications.dart';
import '../core/school_time.dart';
import '../data/closure_scheduler.dart';
import '../data/db.dart';

class LessonAlerts {
  LessonAlerts(this.db);

  final AppDb db;

  /// إعداد «الليثَمَّت تَنبيهُه»: قيم `date:slot:kind` مفصولة بفواصل.
  static const String _shownKey = 'lesson_alerts_shown';

  /// قيم الإعدادات المُتحكّمة (أسماء المفاتيح ثابتة).
  static const String _enabledKey = 'lesson_alerts_enabled';
  static const String _soundKey = 'lesson_alerts_sound';

  /// معرّف إشعار ثابت لكل (حصة، لحظة): يسمح بإلغاء دقيق إن دعمت
  /// طبقة النظام ذلك، ولا يعتمد على قيم عشوائية.
  static int _notificationId(int slot, bool isStart) => slot * 2 + (isStart ? 0 : 1);

  /// يفحص الجدولة ويعرض التنبيهات المتأخرة. يعيد عدد ما أُعرض.
  Future<int> sync({DateTime? now}) async {
    final DateTime at = now ?? DateTime.now();
    final Map<String, String> settings = await db.effectiveSettings();
    if (settings[_enabledKey] != '1') {
      return 0;
    }
    if (!await ClosureScheduler.isSchoolDay(db, at, settings)) {
      return 0;
    }
    final List<LessonWindow> lessons = await db.lessonWindows();
    final String dateKey = SchoolTime.dateKey(at);
    final Set<String> shown = _shown(settings[_shownKey]);

    final bool sound = settings[_soundKey] == '1';
    int fired = 0;
    for (final LessonWindow l in lessons) {
      final int? start = parseArrivalMinutes(l.start);
      final int? end = parseArrivalMinutes(l.end);
      if (start == null || end == null) {
        continue; // وقت تالف: لا موعد يمكن تحديده — تُتخطى الحصة.
      }
      final DateTime startAt = _at(dateKey, start);
      final DateTime endAt = _at(dateKey, end);
      if (!at.isBefore(startAt)) {
        fired += await _fire(
          l,
          dateKey,
          isStart: true,
          at: startAt,
          shown: shown,
          sound: sound,
        );
      }
      if (!at.isBefore(endAt)) {
        fired += await _fire(
          l,
          dateKey,
          isStart: false,
          at: endAt,
          shown: shown,
          sound: sound,
        );
      }
    }
    // تنظيف القيم القديمة (ما قبل اليوم) ثم حفظ حالة اليوم.
    await db.setSetting(
      _shownKey,
      <String>[
        for (final String e in shown)
          if (e.split(':').first == dateKey) e,
      ].join(','),
    );
    return fired;
  }

  /// يُعرض التنبيه إن لم يُعرض من قبل، ويُسجّله في مجموعة [shown].
  Future<int> _fire({
    required LessonWindow lesson,
    required String dateKey,
    required bool isStart,
    required DateTime at,
    required Set<String> shown,
    required bool sound,
  }) async {
    final String entry = '$dateKey:${lesson.slot}:${isStart ? 'start' : 'end'}';
    if (shown.contains(entry)) {
      return 0;
    }
    shown.add(entry);
    final bool shownOk = await LocalNotifications.showLessonAlert(
      id: _notificationId(lesson.slot, isStart),
      title: isStart ? 'بدء الحصة' : 'انتهاء الحصة',
      body: isStart
          ? 'بدأت ${lesson.displayName} — ${_hhmm(at)}'
          : 'انتهت ${lesson.displayName} — ${_hhmm(at)}',
      payload: '',
      sound: sound,
    );
    // حتى إن لم يعرض النظام التنبيه (الصلاحية/التعطيل) تبقى الحالة
    // مسجّلة فلا يُكرر المحاولة في الدورات التالية — الاسترداد عند
    // إعادة التمكين أو الغد.
    return shownOk ? 1 : 0;
  }

  /// مجموعة قيم «تم التنبيه» من الإعداد — تحلل التنسيق وتتجاهل القيم
  /// المشوَّشة.
  Set<String> _shown(String? raw) => <String>{
        for (final String e in (raw ?? '').split(','))
          if (e.isNotEmpty && e.contains(':')) e,
      };

  /// يبني لحظة من تاريخ (`yyyy-mm-dd`) ودقيقة منذ منتصف الليل.
  static DateTime _at(String dateKey, int minutes) {
    final List<String> parts = dateKey.split('-');
    if (parts.length == 3) {
      return DateTime(
        int.tryParse(parts[0]) ?? 0,
        int.tryParse(parts[1]) ?? 1,
        int.tryParse(parts[2]) ?? 1,
        minutes ~/ 60,
        minutes % 60,
      );
    }
    return DateTime(2000, 1, 1, minutes ~/ 60, minutes % 60);
  }

  /// صيغة `HH:mm` للحظة.
  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
