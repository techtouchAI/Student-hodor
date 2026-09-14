/// مزوّدات الحالة العامة (Riverpod).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

final FutureProvider<AcademicYear?> currentYearProvider =
    FutureProvider<AcademicYear?>((Ref ref) => ref.watch(dbProvider).activeYear());

/// بوابة PIN: true بعد إدخال رمز صحيح أو عند عدم وجود رمز.
final StateProvider<bool> pinUnlockedProvider =
    StateProvider<bool>((Ref ref) => false);
