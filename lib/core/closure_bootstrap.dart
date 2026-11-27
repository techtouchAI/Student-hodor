/// عقدة الجذر لتشغيل الإقفال التلقائي: تُركَّب فوق كل المسارات.
///
/// في كل إقلاع (بارد أو خلفية→واجهة):
/// 1. **استرداد**: تنفيذ كل مهمات الإقفال التي تأخر موعدها (إغلاق
///    التطبيق، قتله، إعادة تشغيل الهاتف، أو منع أندرويد تشغيل التنبيه).
/// 2. **إعادة بناء الجدولة** من البيانات الفعلية (الحصص/الصفوف/أيام
///    الدوام) وترتيب التنبيهات الأصلية لليوم والغد.
///
/// لا يعتمد على أي شاشة: يعمل في الخلفية عند عودة التطبيق للواجهة،
/// وكل عطل يُسجَّل في سجل الأعطال دون أن يوقف الإقلاع.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/closure_scheduler.dart';
import '../data/db.dart';
import '../data/error_log.dart';
import 'closure_native.dart';
import '../state/providers.dart';

class ClosureBootstrap extends ConsumerStatefulWidget {
  const ClosureBootstrap({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ClosureBootstrap> createState() => _ClosureBootstrapState();
}

class _ClosureBootstrapState extends ConsumerState<ClosureBootstrap>
    with WidgetsBindingObserver {
  bool _startupDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_runStartup());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // عودة من الخلفية (أو بعد فتح رابط): استرداد المهمات المتأخرة فقط —
      // الجدولة الكاملة تُبنى في الإقلاع، وهذا الاسترداد رخيص وذرّي.
      unawaited(_recover());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  ClosureScheduler _scheduler(AppDb db) => ClosureScheduler(
        db,
        bridge: const MethodChannelClosureBridge(
          MethodChannelClosureBridge.closureChannel,
        ),
      );

  Future<void> _runStartup() async {
    if (_startupDone) {
      return;
    }
    _startupDone = true;
    try {
      await _scheduler(ref.read(dbProvider)).startup();
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'closure:startup');
    }
  }

  Future<void> _recover() async {
    try {
      await _scheduler(ref.read(dbProvider)).recoverDue();
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'closure:recover');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
