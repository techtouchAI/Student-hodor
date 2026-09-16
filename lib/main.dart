import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/error_guard.dart';
import 'data/error_log.dart';

void main() {
  runZonedGuarded<void>(() {
    WidgetsFlutterBinding.ensureInitialized();
    // لا صفحة بيضاء صامتة: كل عطل يُسجَّل ويُعرض بدل ودجت الخطأ الفارغ.
    installErrorGuards();
    // تحميل سجل الأعطال السابق قبل أول إطار (لا يلمس القاعدة: تُفتح مرة واحدة
    // عبر `dbProvider` حتى لا يتنازع عزلان على ملف SQLite نفسه).
    unawaited(AppErrorLog.instance.load());
    runApp(const ProviderScope(child: StudentHodorApp()));
  }, (Object error, StackTrace stack) {
    AppErrorLog.instance.record(error, stack, where: 'zone');
  });
}
