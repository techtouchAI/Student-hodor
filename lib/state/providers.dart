/// مزوّدات الحالة العامة (Riverpod).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
