/// خدمة التنبيهات: تدير تنبيهات حد الفصل من **نفس مصدر التقارير** — إنذار
/// `ReportsService.alerts(yearId, العتبة)` المبكر — بلا أي احتساب موازٍ هنا.
///
/// قواعد الدلالة (exactly-once):
/// - بلوغ الطالب الحد الثاني (حد الفصل) أول مرة ⇒ تنبيه واحد داخل التطبيق
///   (عدّاد زر الجرس) ولا يتكرر أبدًا؛ إحصاؤه يتحدّث عند كل احتساب ما دام
///   الطالب على القائمة ويُجمَّد بعده (يبقى سجلًّا تاريخيًّا).
/// - إشعار النظام (خارج التطبيق) يُعرض مرة واحدة لكل تنبيه: إن لم تكن
///   الصلاحية ممنوحة أو كانت الميزة مطفأة تُعاد المحاولة تلقائيًا عند
///   الاحتساب التالي، ولا يُعاد أبدًا بعد النجاح.
/// - [sync] يعيد معرّفات تنبيهات السنة الفعّالة الحالية حتى يلغي المستدعي
///   إشعارات النظام التي حُذفت سطورها (حذف الطالب).
library;

import 'dart:convert';

import '../core/local_notifications.dart';
import 'db.dart';
import 'reports_service.dart';

/// أنواع التنبيهات (حاليًا: حد الفصل = العتبة الثانية فقط).
class AlertKinds {
  AlertKinds._();

  static const String threshold2 = 'threshold_2';
}

class NotificationsService {
  NotificationsService(this.db);

  final AppDb db;

  /// إعادة احتساب كاملة: مَن بلغ الحد الثاني الآن؟
  ///
  /// المصدر هو استعلام التقارير نفسه بعتبتها — لا تكرار منطق هنا.
  Future<Set<int>> sync() async {
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return <int>{};
    }
    final Map<String, String> settings = await db.effectiveSettings();
    final double threshold = _threshold2(settings);
    if (threshold <= 0) {
      return <int>{};
    }
    final List<(Student, StatusTotals)> crossed =
        await ReportsService(db).alerts(year.id, threshold);
    for (final (Student s, StatusTotals t) in crossed) {
      await db.recordAlertCrossing(
        yearId: year.id,
        studentId: s.id,
        absentDays: t.absent,
        recordedDays: t.recorded,
        thresholdDays: threshold,
        kind: AlertKinds.threshold2,
      );
    }
    await _firePendingSystemAlerts(year, settings);
    return <int>{
      for (final AlertNotification n in await db.alertsOfYear(year.id)) n.id,
    };
  }

  /// يعرض الإشعارات المعلقة (بانتظار الصلاحية/الميزة/إقلاع). يمرّ بصمت
  /// إن لم تتحقق الشروط — تُعاد المحاولة في الاحتساب التالي.
  Future<void> _firePendingSystemAlerts(
    AcademicYear year,
    Map<String, String> settings,
  ) async {
    if (settings['system_notifications_enabled'] == '0') {
      return;
    }
    if (!await LocalNotifications.areNotificationsEnabled()) {
      return;
    }
    final List<AlertNotification> pending =
        await db.pendingSystemAlerts(year.id);
    for (final AlertNotification n in pending) {
      final Student? student = await db.studentById(n.studentId);
      if (student == null) {
        continue;
      }
      final bool shown = await LocalNotifications.showThreshold2(
        id: n.id,
        title: 'تنبيه حد الفصل',
        body:
            '${student.fullName}: بلغ ${n.absentDays} أيام غياب '
            '(الحد: ${formatDays(n.thresholdDays)} يوم) — '
            'افتح ملف الطالب لعرض الكشف',
        payload: jsonEncode(
          payloadOf(
            notificationId: n.id,
            yearId: n.yearId,
            studentId: n.studentId,
          ),
        ),
      );
      if (shown) {
        await db.markAlertSystemShown(n.id);
      }
    }
  }

  /// وسم تنبيه واحد مقروءًا (فتح من زر الجرس أو من إشعار النظام).
  Future<void> markRead(int alertId) => db.markAlertRead(alertId);

  /// وسم كل تنبيهات السنة مقروءة — يعيد عدد ما وُسِم.
  Future<int> markAllRead(int yearId) => db.markAllAlertsRead(yearId);

  static double _threshold2(Map<String, String> settings) =>
      double.tryParse(settings['alert_threshold_2'] ?? '15') ?? 15;

  /// عدد أيام كـ«15» لا «15.0» — إلا إذا نصّت العتبة على كسر.
  static String formatDays(double days) =>
      days == days.roundToDouble() ? days.toInt().toString() : days.toString();
}

/// حمولة الإشعار: النقرة تفتح ملف الطالب وتوسم التنبيه مقروءًا.
Map<String, Object> payloadOf({
  required int notificationId,
  required int yearId,
  required int studentId,
}) =>
    <String, Object>{
      'type': 'student',
      'notificationId': notificationId,
      'yearId': yearId,
      'studentId': studentId,
    };

/// يحلل حمولة الإشعار (JSON) إلى `(المعرّف، المسار)`. يعيد `null` عند
/// غياب السطر أو تالفه — لا يجوز أن ينهار التطبيق من نقرة إشعار.
({int? notificationId, String? route})? notificationPayloadOf(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  Object? decoded;
  try {
    decoded = json.decode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?> || decoded['type'] != 'student') {
    return null;
  }
  final Object? sid = decoded['studentId'];
  final int? studentId = sid is int ? sid : int.tryParse('${sid ?? ''}');
  final Object? nid = decoded['notificationId'];
  final int? notificationId = nid is int ? nid : int.tryParse('${nid ?? ''}');
  return (
    notificationId: notificationId,
    route: studentId == null ? null : '/student/$studentId',
  );
}
