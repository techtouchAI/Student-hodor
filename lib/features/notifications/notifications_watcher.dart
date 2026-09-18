/// حارس التنبيهات الجذري: يُركَّب مرة واحدة فوق كل الشاشات، ويعمل بلا
/// لمس أي شاشة:
///
/// 1. يهيّئ طبقة إشعارات النظام ويلتقط رابط نقرة الإشعار التي أطلقت
///    إقلاعًا باردًا (الشاشة الأولى توجّه المستخدم إلى ملف الطالب بعد
///    تحميل الإعدادات).
/// 2. يستمع لأي تغيير في مدخلات التنبيهات (حضور/إعدادات/طلاب/سنة/
///    تنبيهات) ويعيد — بعد مهلة قصيرة تُجمع الدفعات المتتالية — الاحتساب
///    من **نفس مصدر التقارير** مَن بلغ حد الفصل: إنشاء/تحديث التنبيهات
///    داخل التطبيق وعرض إشعارات النظام المعلقة، وإلغاء أي إشعار نظام
///    ضاعت سطرته (حذف الطالب).
/// 3. يعالج نقرة إشعار النظام (تطبيق مفتوح/خلفية/مغلق): التنقل إلى ملف
///    الطالب ووسم التنبيه مقروءًا.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/local_notifications.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../data/notifications_service.dart';
import '../../state/providers.dart';

class NotificationsWatcher extends ConsumerStatefulWidget {
  const NotificationsWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<NotificationsWatcher> createState() =>
      _NotificationsWatcherState();
}

class _NotificationsWatcherState extends ConsumerState<NotificationsWatcher> {
  StreamSubscription<void>? _inputs;
  Timer? _debounce;
  bool _syncing = false;

  /// معرّفات السنة الفعّالة التي رأيناها في آخر احتساب ناجح — أساس
  /// إلغاء إشعارات النظام اليتيمة.
  Set<int> _lastKnownIds = <int>{};

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await LocalNotifications.ensureInitialized(onTap: _onTap);
      final String? coldPayload = await LocalNotifications.coldLaunchPayload();
      final ({int? notificationId, String? route})? parsed =
          notificationPayloadOf(coldPayload);
      final String? route = parsed?.route;
      if (route != null) {
        ref.read(pendingNotificationRouteProvider.notifier).state = route;
      }
      await _markRead(parsed?.notificationId);
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'notifications:init');
    } finally {
      // إشارة الجاهزية (تشمل الفشل) — الشاشة الأولى لا تتنقل قبلها.
      if (mounted) {
        ref.read(notificationInitDoneProvider.notifier).state = true;
      }
    }
    if (!mounted) {
      return;
    }
    try {
      final AppDb db = ref.read(dbProvider);
      _inputs = db.watchAlertInputs().listen((_) => _scheduleSync());
      await _syncNow();
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'notifications:watch');
    }
  }

  /// مهلة قصيرة: إقفال جلسة واحد يولّد عشرات السجلات دفعة واحدة —
  /// نحتسب مرة واحدة بعد هدوء الدفعة لا لكل سجل.
  void _scheduleSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_syncNow());
    });
  }

  Future<void> _syncNow() async {
    if (_syncing || !mounted) {
      return;
    }
    _syncing = true;
    try {
      final Set<int> current =
          await NotificationsService(ref.read(dbProvider)).sync();
      // سطر حُذف (حذف طالب/تغيير سنة) ⇒ إشعاره في النظام يتيم ⇒ ألغه.
      for (final int gone in _lastKnownIds.difference(current)) {
        await LocalNotifications.cancel(gone);
      }
      _lastKnownIds = current;
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'notifications:sync');
    } finally {
      _syncing = false;
    }
  }

  /// نقرة على إشعار النظام بأي حالة: ملف الطالب + وسم مقروء.
  Future<void> _onTap(String payload) async {
    final ({int? notificationId, String? route})? parsed =
        notificationPayloadOf(payload);
    final String? route = parsed?.route;
    if (route != null) {
      try {
        ref.read(appRouterProvider).go(route);
      } catch (e, st) {
        AppErrorLog.instance.record(e, st, where: 'notifications:navigate');
      }
    }
    await _markRead(parsed?.notificationId);
  }

  Future<void> _markRead(int? alertId) async {
    if (alertId == null) {
      return;
    }
    try {
      await NotificationsService(ref.read(dbProvider)).markRead(alertId);
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'notifications:markRead');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    final Future<void>? cancel = _inputs?.cancel();
    if (cancel != null) {
      unawaited(cancel);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
