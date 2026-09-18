/// التنبيهات داخل التطبيق: طلاب بلغوا حد الفصل (العتبة الثانية) في السنة
/// الفعّالة — نفس مصدر الإنذار المبكر في التقارير. الضغط على تنبيه يفتح
/// ملف الطالب ويوسمه مقروءًا، وزر «وسم الكل» يصفّر الشارة.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error_guard.dart';
import '../../data/db.dart';
import '../../data/notifications_service.dart';
import '../../state/providers.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('التنبيهات'),
        actions: <Widget>[
          _MarkAllReadButton(db: db),
        ],
      ),
      body: StreamBuilder<AcademicYear?>(
        stream: db.watchActiveYear(),
        builder: (BuildContext context, AsyncSnapshot<AcademicYear?> years) {
          final AcademicYear? year = years.data;
          if (year == null) {
            return const Center(child: Text('لا سنة فعّالة'));
          }
          return _AlertList(db: db, year: year);
        },
      ),
    );
  }
}

/// زر «وسم الكل مقروءًا» — يظهر فقط عند وجود تنبيهات غير مقروءة.
class _MarkAllReadButton extends ConsumerWidget {
  const _MarkAllReadButton({required this.db});

  final AppDb db;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            if ((countSnap.data ?? 0) == 0) {
              return const SizedBox.shrink();
            }
            return IconButton(
              tooltip: 'وسم الكل مقروءًا',
              icon: const Icon(Icons.done_all),
              onPressed: () async {
                await NotificationsService(db).markAllRead(year.id);
              },
            );
          },
        );
      },
    );
  }
}

/// قائمة التنبيهات الحية: غير المقروء أولاً ثم الأحدث. أسماء الطلاب تُحل
/// باستعلام واحد لكل تغيير (لا استعلام لكل سطر).
class _AlertList extends ConsumerWidget {
  const _AlertList({required this.db, required this.year});

  final AppDb db;
  final AcademicYear year;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<List<AlertNotification>>(
      stream: db.watchAlerts(year.id),
      builder: (
        BuildContext context,
        AsyncSnapshot<List<AlertNotification>> alerts,
      ) {
        final List<AlertNotification>? rows = alerts.data;
        if (rows == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return FutureBuilder<Map<int, String>>(
          future: _studentNames(db, year.id),
          builder: (
            BuildContext context,
            AsyncSnapshot<Map<int, String>> namesSnap,
          ) {
            if (namesSnap.hasError) {
              return LoadErrorCard(
                message: 'تعذر تحميل الأسماء: ${namesSnap.error}',
              );
            }
            if (namesSnap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final Map<int, String> names =
                namesSnap.data ?? const <int, String>{};
            if (rows.isEmpty) {
              return const Center(
                child: Text('لا تنبيهات — لا طلاب بلغوا حد الفصل بعد'),
              );
            }
            return ListView(
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'طلاب بلغوا الحد الثاني (حد الفصل) في السنة الفعّالة — '
                    'نفس مصدر الإنذار المبكر في التقارير. الضغط يفتح ملف '
                    'الطالب.',
                    style: TextStyle(color: Colors.black54, fontSize: 13),
                  ),
                ),
                for (final AlertNotification alert in rows)
                  _AlertTile(
                    db: db,
                    alert: alert,
                    name: names[alert.studentId] ?? 'طالب',
                  ),
              ],
            );
          },
        );
      },
    );
  }

  static Future<Map<int, String>> _studentNames(
    AppDb db,
    int yearId,
  ) async {
    final List<Student> students =
        await (db.select(db.students)..where((s) => s.yearId.equals(yearId)))
            .get();
    return <int, String>{
      for (final Student s in students) s.id: s.fullName,
    };
  }
}

class _AlertTile extends ConsumerWidget {
  const _AlertTile({required this.db, required this.alert, required this.name});

  final AppDb db;
  final AlertNotification alert;
  final String name;

  Future<void> _open(BuildContext context) async {
    await NotificationsService(db).markRead(alert.id);
    if (context.mounted) {
      // الانتقال «نا» — لا نبقيه معلقًا في الـ Future.
      unawaited(context.push('/student/${alert.studentId}'));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool unread = !alert.read;
    final int recorded = alert.recordedDays;
    final double pct = recorded == 0 ? 0 : alert.absentDays * 100 / recorded;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: unread ? Colors.red : Colors.orange,
        child: const Icon(Icons.warning_amber, color: Colors.white),
      ),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontWeight: unread ? FontWeight.bold : null,
              ),
            ),
          ),
          if (unread)
            const SizedBox(
              width: 8,
              height: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        'غياب ${alert.absentDays} من $recorded يوم '
        '(${pct.toStringAsFixed(1)}%) — حد الفصل: '
        '${NotificationsService.formatDays(alert.thresholdDays)} يوم • '
        'في ${alert.occurredAt.substring(0, 10)}',
      ),
      onTap: () => _open(context),
    );
  }
}
