/// مزوّدات الحالة العامة (Riverpod).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/school_time.dart';
import '../data/db.dart';

final Provider<AppDb> dbProvider = Provider<AppDb>((Ref ref) {
  final AppDb db = AppDb();
  ref.onDispose(db.close);
  return db;
});

final FutureProvider<Map<String, String>> settingsProvider =
    FutureProvider<Map<String, String>>(
  (Ref ref) => ref.watch(dbProvider).allSettings(),
);

/// الإعدادات فوق القيم الافتراضية — ما تعرضه الشاشات دائماً.
final FutureProvider<Map<String, String>> effectiveSettingsProvider =
    FutureProvider<Map<String, String>>(
  (Ref ref) => ref.watch(dbProvider).effectiveSettings(),
);

final FutureProvider<AcademicYear?> currentYearProvider =
    FutureProvider<AcademicYear?>((Ref ref) => ref.watch(dbProvider).activeYear());

/// هل انتهى الامداد الزمني للسنة الفعّالة؟ (يُظهر خيارات نهاية السنة).
final FutureProvider<bool> yearEndedProvider = FutureProvider<bool>(
  (Ref ref) async {
    final AcademicYear? y = await ref.watch(dbProvider).activeYear();
    if (y == null) {
      return false;
    }
    return DateTime.now().isAfter(SchoolTime.parseKey(y.end));
  },
);

/// بوابة PIN: true بعد إدخال رمز صحيح أو عند عدم وجود رمز.
final StateProvider<bool> pinUnlockedProvider =
    StateProvider<bool>((Ref ref) => false);

/// راوتر التطبيق — مصدر وحيد: يستخدمه حارس التنبيهات للتنقل من نقرة
/// إشعار نظام دون حاجة إلى سياق داخل الراوتر. (يُنشأ فقط إن لم يُحقن
/// راوتر خاص بالاختبار في `StudentHodorApp`.)
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((Ref ref) {
  final GoRouter router = buildRouter();
  ref.onDispose(router.dispose);
  return router;
});

/// مسار نقرة إشعار نظام أطلقت إقلاعًا باردًا: تستهلكه الشاشة الأولى بعد
/// تحميل الإعدادات (null = إقلاع عادي).
final StateProvider<String?> pendingNotificationRouteProvider =
    StateProvider<String?>((Ref ref) => null);

/// اكتملت تهيئة طبقة الإشعارات (نجاحًا كان أم فشلًا): تحجز بها الشاشة
/// الأولى تنقّلها الأول حتى لا تفوت رابط نقرة الإشعار الذي يصل متأخرًا
/// بمقدار ذهاب/إياب قناة المنصة.
final StateProvider<bool> notificationInitDoneProvider =
    StateProvider<bool>((Ref ref) => false);
