/// زر التنبيه داخل التطبيق: أعلى التطبيق في نفس سطر اسم التطبيق، بشارة
/// تحمل عدد التنبيهات غير المقروءة (طلاب بلغوا حد الفصل في السنة الفعّالة).
/// الضغط يفتح قائمة التنبيهات.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/nav.dart';
import '../../data/db.dart';
import '../../state/providers.dart';

class NotificationsBell extends ConsumerWidget {
  const NotificationsBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppDb db = ref.watch(dbProvider);
    return StreamBuilder<AcademicYear?>(
      stream: db.watchActiveYear(),
      builder: (BuildContext context, AsyncSnapshot<AcademicYear?> years) {
        final AcademicYear? year = years.data;
        if (year == null) {
          return const SizedBox.shrink();
        }
        return StreamBuilder<int>(
          stream: db.unreadAlertCount(year.id),
          builder: (BuildContext context, AsyncSnapshot<int> countSnap) {
            final int unread = countSnap.data ?? 0;
            return IconButton(
              tooltip: 'التنبيهات',
              icon: Badge(
                isLabelVisible: unread > 0,
                label: Text(unread > 99 ? '99+' : '$unread'),
                child: const Icon(Icons.notifications),
              ),
              onPressed: () => context.pushNamed(AppRoutes.notifications),
            );
          },
        );
      },
    );
  }
}
