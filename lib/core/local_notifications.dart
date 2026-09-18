/// طبقة النظام (خارج التطبيق): إشعارات نظام أندرويد عبر
/// `flutter_local_notifications` — الأداة المعتمدة لهذا الغرض في منظومة
/// Flutter (لا قنوات يدوية متفرقة):
///
/// - قناة إشعارات مخصصة (أندرويد 8+) لحد الفصل بأولوية عالية: نظام
///   أندرويد هو من يعرض الإشعار **المنبثق** (heads-up) بالصوت والاهتزاز.
/// - صلاحية `POST_NOTIFICATIONS` في أندرويد 13+ تُطلب عبر حوار النظام
///   بموافقة المستخدم؛ في الإصدارات الأقدم هي ضمن صلاحية التثبيت.
/// - نقرة الإشعار معتمدة في كل الحالات: `onDidReceiveNotificationResponse`
///   بينما التطبيق مفتوح أو في الخلفية، و`getNotificationAppLaunchDetails`
///   عند الإقلاع البارد من الإشعار.
///
/// الفئة أحادية آمنة في اختبارات الوحدة: عند غياب طبقة المنصة (أو فشلها)
/// تعيد كل النداءات `false`/`null` بهدوء دون رمي استثناء، وتبقى الإشعارات
/// المعلّقة لإعادة المحاولة في الاحتساب التالي.
library;

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../data/error_log.dart';

/// أحادية آمنة لخدمة الإشعارات.
class LocalNotifications {
  LocalNotifications._();

  /// قناة: حد الفصل (العتبة الثانية). أهمية عالية ⇒ إشعار منبثق بالصوت
  /// والاهتزاز (مسؤولية نظام أندرويد لا بنا).
  static const String _channelId = 'alert_threshold_2';
  static const String _channelName = 'تنبيهات حد الفصل';
  static const String _channelDescription =
      'تُرفع عندما يبلغ الطالب الحد الثاني من أيام الغياب';

  /// أيقونة صغيرة بيضاء (طبقة launcher أحادية اللون) — أفضل الممارسات
  /// لأيقونات الإشعارات.
  static const String _icon = 'ic_launcher_monochrome';

  /// قناة نحو الطبقة الأصلية: فتح صفحة إعدادات إشعارات التطبيق في النظام.
  static const MethodChannel _native =
      MethodChannel('iq.techtouch.student_hodor.notifications');

  static FlutterLocalNotificationsPlugin? _plugin;
  static bool _ready = false;
  static void Function(String payload)? _onTap;

  /// هل طبقة المنصة جاهزة؟ (false دائمًا في اختبارات الوحدة).
  static bool get isReady => _ready;

  /// يهيّئ الوسيطة ويسجّل معالج النقر. عملية: إعادة النداء تحدّث المعالج
  /// فقط ولا تعيد التهيئة.
  static Future<void> ensureInitialized({
    required void Function(String payload) onTap,
  }) async {
    _onTap = onTap;
    if (_ready) {
      return;
    }
    try {
      final FlutterLocalNotificationsPlugin plugin =
          FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(_icon),
        ),
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final void Function(String payload) handler =
              _onTap ?? (String payload) {};
          handler(response.payload ?? '');
        },
      );
      _plugin = plugin;
      _ready = true;
    } catch (e, st) {
      _log(e, st, 'init');
    }
  }

  /// هل النظام يسمح بالإظهار؟ (الصلاحية في أندرويد 13+، ووضع الصمت
  /// العام في كل الإصدارات).
  static Future<bool> areNotificationsEnabled() async {
    final FlutterLocalNotificationsPlugin? plugin = _plugin;
    if (!_ready || plugin == null) {
      return false;
    }
    try {
      final AndroidFlutterLocalNotificationsPlugin? android = plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final bool? enabled = await android?.areNotificationsEnabled();
      return enabled ?? false;
    } catch (e, st) {
      _log(e, st, 'check');
      return false;
    }
  }

  /// يطلب صلاحية التشغيل (أندرويد 13+). يعيد `true` فورًا في الإصدارات
  /// الأقدم إذ لا توجد صلاحية تشغيلية هناك.
  static Future<bool> requestPermission() async {
    final FlutterLocalNotificationsPlugin? plugin = _plugin;
    if (!_ready || plugin == null) {
      return false;
    }
    try {
      final AndroidFlutterLocalNotificationsPlugin? android = plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    } catch (e, st) {
      _log(e, st, 'permission');
      return false;
    }
  }

  /// يفتح صفحة إعدادات إشعارات التطبيق في النظام (تشغيل/إيقاف الصلاحية
  /// والقنوات). بديل عام: صفحة تفاصيل التطبيق إن تعذر ذلك.
  static Future<void> openNotificationSettings() async {
    try {
      await _native.invokeMethod<void>('openNotificationSettings');
      return;
    } on PlatformException {
      // المعالج غير مسجّل (تباين إصدارات) ⇒ البديل أدناه.
    } on MissingPluginException {
      // لا طبقة أصلية (اختبارات وحدة) ⇒ البديل أدناه.
    }
    final FlutterLocalNotificationsPlugin? plugin = _plugin;
    if (plugin == null) {
      return;
    }
    try {
      // الوسيطة نفسها تفتح صفحة «إدارة إشعارات التطبيق» في النظام.
      await plugin.openAppNotificationSettings();
    } catch (e, st) {
      _log(e, st, 'openSettings');
    }
  }

  /// يعرض إشعار حد الفصل. يعيد `false` إن لم يُعرض (الطبقة غير جاهزة/
  /// رفض النظام) — يترك المستدعي `systemShown = false` فتُعاد المحاولة
  /// في الاحتساب التالي.
  static Future<bool> showThreshold2({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    final FlutterLocalNotificationsPlugin? plugin = _plugin;
    if (!_ready || plugin == null) {
      return false;
    }
    try {
      await plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          icon: _icon,
        ),
        payload: payload,
      );
      return true;
    } catch (e, st) {
      _log(e, st, 'show');
      return false;
    }
  }

  /// يلغي إشعار النظام بالمعرّف (تنبيه حُذف طالبه مثلاً).
  static Future<void> cancel(int id) async {
    final FlutterLocalNotificationsPlugin? plugin = _plugin;
    if (!_ready || plugin == null) {
      return;
    }
    try {
      await plugin.cancel(id: id);
    } catch (e, st) {
      _log(e, st, 'cancel');
    }
  }

  /// الـ payload لنقرة أطلقت إقلاعًا باردًا (كان التطبيق مغلقًا كليًا)،
  /// أو `null` عند الإقلاع العادي.
  static Future<String?> coldLaunchPayload() async {
    final FlutterLocalNotificationsPlugin? plugin = _plugin;
    if (!_ready || plugin == null) {
      return null;
    }
    try {
      final NotificationAppLaunchDetails? details =
          await plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) {
        return null;
      }
      return details.initialNotificationResponse?.payload;
    } catch (e, st) {
      _log(e, st, 'coldLaunch');
      return null;
    }
  }

  static void _log(Object error, StackTrace stack, String where) {
    AppErrorLog.instance.record(
      error,
      stack,
      where: 'local_notifications:$where',
    );
  }
}
