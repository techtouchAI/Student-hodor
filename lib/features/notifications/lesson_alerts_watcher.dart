/// حارس تنبيهات الحصص: يُركَّب مرة واحدة فوق كل الشاشات، ويفحص جدولة
/// الحصص بشكل دوري (كل دقيقة) ليعرض تنبيه بداية/نهاية كل حصة تلقائيًا
/// بلا لمس أي شاشة.
///
/// يتبع نفس منطق [NotificationsWatcher]: طبقة النظام تُهيَّأ في الحرس
/// الأصل، والفحص دوري لا يعتمد على أي شاشة مفتوحة. أي فشل في عرض
/// التنبيه لا يوقف الدورة — الاسترداد يحصل في الدورة التالية أو بعد
/// إعادة التمكين.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/lesson_alerts.dart';
import '../../data/error_log.dart';
import '../../state/providers.dart';

class LessonAlertsWatcher extends ConsumerStatefulWidget {
  const LessonAlertsWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LessonAlertsWatcher> createState() =>
      _LessonAlertsWatcherState();
}

class _LessonAlertsWatcherState extends ConsumerState<LessonAlertsWatcher> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // مهلة قصيرة في الإقلاع: طبقة الإشعارات تُهيَّأ في الحرس الأصل
    // (NotificationsWatcher) قبل أن تصل أول دورة هنا.
    Timer(const Duration(milliseconds: 500), _tick);
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    if (!mounted) {
      return;
    }
    try {
      await LessonAlerts(ref.read(dbProvider)).sync();
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'lessonAlerts:tick');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
