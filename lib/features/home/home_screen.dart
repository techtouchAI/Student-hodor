/// الشاشة الرئيسة: بطاقة المدرسة/اليوم + جلسات اليوم + شبكة الوحدات +
/// بوابة PIN + زر التنبيهات (حد الفصل).
library;

import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error_guard.dart';
import '../../core/local_notifications.dart';
import '../../core/nav.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../data/years_service.dart';
import '../../state/providers.dart';
import '../notifications/notifications_bell.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeState();
}

class _HomeState extends ConsumerState<HomeScreen> {
  late final String _today;
  late final Stream<List<AttendanceRow>> _todayRows;
  late final Stream<List<Session>> _todaySessions;

  @override
  void initState() {
    super.initState();
    _today = SchoolTime.dateKey(DateTime.now());
    final AppDb db = ref.read(dbProvider);
    _todayRows = (db.select(db.attendanceRows)
          ..where((a) => a.date.equals(_today)))
        .watch();
    _todaySessions = (db.select(db.sessions)
          ..where((s) => s.date.equals(_today)))
        .watch();
    _classes = (db.select(db.schoolClasses)
          ..orderBy(<OrderClauseGenerator<SchoolClasses>>[
            (SchoolClasses c) => OrderingTerm.asc(c.grade),
            (SchoolClasses c) => OrderingTerm.asc(c.section),
          ]))
        .watch();
    // مرة واحدة فقط (أول إقلاع بعد الإعداد الأولي): شرح قصير ثم طلب
    // صلاحية الإشعارات من النظام (طبقة «خارج التطبيق»).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_maybeRequestNotificationPermission());
      }
    });
  }

  /// طلب صلاحية إشعارات النظام: مرّة واحدة لكل جهاز (لا إزعاج متكرر).
  /// إن مُنحت ⇒ يحتسب الحارس فورًا ويُظهر أي تنبيهات معلقة.
  Future<void> _maybeRequestNotificationPermission() async {
    final AppDb db = ref.read(dbProvider);
    try {
      if (await db.setting('notifications_permission_asked') != null) {
        return;
      }
      await db.setSetting('notifications_permission_asked', '1');
      // أندرويد أقدم من 13: الصلاحية ضمن التثبيت — لا حوار نظام.
      if (await LocalNotifications.areNotificationsEnabled()) {
        await db.setSetting('notifications_permission_state', 'granted');
        return;
      }
      if (!mounted) {
        return;
      }
      final bool? agreed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          icon: const Icon(Icons.notifications, size: 40),
          title: const Text('السماح بالإشعارات؟'),
          content: const Text(
            'ليُنبهك التطبيق لحظة بلوغ أي طالب الحد الثاني (حد الفصل) '
            'يلزمه إذن بإظهار إشعارات النظام على هاتفك — إضافةً إلى '
            'التنبيهات داخل التطبيق.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('ليس الآن'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('السماح'),
            ),
          ],
        ),
      );
      if (agreed != true) {
        return;
      }
      final bool granted = await LocalNotifications.requestPermission();
      if (!mounted) {
        return;
      }
      await db.setSetting(
        'notifications_permission_state',
        granted ? 'granted' : 'denied',
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            granted
                ? 'فُعّلت الإشعارات — تنبيهات حد الفصل ستظهر على هاتفك'
                : 'لم تُمنح الصلاحية — تطلبها لاحقًا من شاشة الإعدادات',
          ),
        ),
      );
    } catch (e, st) {
      AppErrorLog.instance.record(
        e,
        st,
        where: 'home:notification-permission',
      );
    }
  }

  late final Stream<List<SchoolClass>> _classes;

  Future<(int, String)?> _pickClass(BuildContext context, AppDb db) async {
    AcademicYear? year;
    List<SchoolClass> classes;
    try {
      year = await db.activeYear();
      if (year == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('لا توجد سنة فعّالة — أنشئها من شاشة السنوات'),
            ),
          );
        }
        return null;
      }
      classes = await (db.select(db.schoolClasses)
            ..where((c) => c.yearId.equals(year!.id)))
          .get();
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'home:pickClass');
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر قراءة الصفوف: $e')));
      }
      return null;
    }
    if (!context.mounted) {
      return null;
    }
    if (classes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا صفوف بعد — أضف من شاشة الصفوف')),
      );
      return null;
    }
    return showDialog<(int, String)>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('اختر صفاً'),
        children: <Widget>[
          for (final SchoolClass c in classes)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, (c.id, '${c.grade} ـ ${c.section}')),
              child: Text('${c.grade} ـ ${c.section}'),
            ),
        ],
      ),
    );
  }

  /// فتح شاشة مرتبطة بصف: الرابط يُبنى بترميز صحيح ويُمرَّر المرجع عبر `extra`
  /// أيضاً، فتصل الشاشة ببياناتها حتى لو فُقدت المعاملات (استعادة عملية/رابط قديم).
  Future<void> _openClassFlow(
    BuildContext context,
    AppDb db,
    String path,
  ) async {
    final (int, String)? p = await _pickClass(context, db);
    if (p == null || !context.mounted) {
      return;
    }
    final ClassRef ref0 = ClassRef(id: p.$1, title: p.$2);
    try {
      await context.push(
        AppRoutes.classLocation(path, ref0.id, ref0.displayTitle),
        extra: ref0,
      );
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'home:push:$path');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر فتح الشاشة: $e')),
        );
      }
    }
  }

  Future<void> _openPin(BuildContext context, WidgetRef ref, String route) async {
    final String? pin = await ref.read(dbProvider).setting('pin');
    if (!context.mounted) {
      return;
    }
    if (pin == null || pin.isEmpty || ref.read(pinUnlockedProvider)) {
      await _push(context, route);
      return;
    }
    final TextEditingController c = TextEditingController();
    final String? entered = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('أدخل رمز PIN'),
        content: TextField(controller: c, obscureText: true),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('دخول'),
          ),
        ],
      ),
    );
    if (entered == pin && context.mounted) {
      ref.read(pinUnlockedProvider.notifier).state = true;
      await _push(context, route);
    } else if (entered != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('رمز غير صحيح')));
    }
  }

  Future<void> _push(BuildContext context, String route) async {
    try {
      await context.push(route);
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'home:push:$route');
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر فتح الشاشة: $e')));
      }
    }
  }

  Future<void> _yearEndOptions(BuildContext context, WidgetRef ref) async {
    final AppDb db = ref.read(dbProvider);
    final AcademicYear? y = await db.activeYear();
    if (y == null || !context.mounted) {
      return;
    }
    final DateTime end = SchoolTime.parseKey(y.end);
    DateTime newStart = DateTime(end.year, 9, 1);
    DateTime newEnd = DateTime(end.year + 1, 6, 30);
    if (!context.mounted) {
      return;
    }
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSt) => AlertDialog(
          title: const Text('انتهت السنة الدراسية'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('السنة ${y.name} انتهت في ${y.end}. اختر الإجراء:'),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('بداية السنة الجديدة'),
                subtitle: Text(SchoolTime.dateKey(newStart)),
                onTap: () async {
                  final DateTime? d = await showDatePicker(
                    context: context,
                    initialDate: newStart,
                    firstDate: DateTime(2015),
                    lastDate: DateTime(2045),
                  );
                  if (d != null) {
                    setSt(() => newStart = d);
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('نهايتها'),
                subtitle: Text(SchoolTime.dateKey(newEnd)),
                onTap: () async {
                  final DateTime? d = await showDatePicker(
                    context: context,
                    initialDate: newEnd,
                    firstDate: DateTime(2015),
                    lastDate: DateTime(2045),
                  );
                  if (d != null) {
                    setSt(() => newEnd = d);
                  }
                },
              ),
              const SizedBox(height: 4),
              FilledButton.icon(
                icon: const Icon(Icons.people_alt),
                label: const Text('سنة جديدة مع إبقاء أسماء الطلاب'),
                onPressed: () => Navigator.pop(context, 'rollover'),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                icon: const Icon(Icons.archive),
                label: const Text('أرشفة السنة الحالية فقط'),
                onPressed: () => Navigator.pop(context, 'archive'),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_forever),
                label: const Text('تصفير شامل (من شاشة السنوات)'),
                onPressed: () => Navigator.pop(context, 'reset'),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) {
      return;
    }
    final YearsService svc = YearsService(db);
    if (choice == 'rollover') {
      if (newStart.isAfter(newEnd)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تاريخ البداية بعد النهاية — صحّح')),
        );
        return;
      }
      final int n = await svc.rolloverKeepNames(
        newStart: newStart,
        newEnd: newEnd,
      );
      ref.invalidate(currentYearProvider);
      ref.invalidate(yearEndedProvider);
      ref.invalidate(settingsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('بدأت سنة جديدة ونُقل $n طالباً بأسمائهم')),
        );
      }
    } else if (choice == 'archive') {
      await svc.closeYear(y.id);
      ref.invalidate(currentYearProvider);
      ref.invalidate(yearEndedProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('أُرشفت السنة؛ تقاريرها تبقى متاحة')),
        );
      }
    } else if (choice == 'reset') {
      await context.push('/years');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    final AsyncValue<Map<String, String>> settings =
        ref.watch(effectiveSettingsProvider);
    final AsyncValue<AcademicYear?> year = ref.watch(currentYearProvider);
    final AsyncValue<bool> ended = ref.watch(yearEndedProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('حضور الطالب'),
        // زر التنبيهات في نفس سطر اسم التطبيق: شارة بعدد غير المقروء.
        actions: const <Widget>[NotificationsBell()],
      ),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, StackTrace st) => Center(child: Text('$e')),
        data: (Map<String, String> s) => year.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object e, StackTrace st) => Center(child: Text('$e')),
          data: (AcademicYear? y) => ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        s['school_name'] ?? '',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text('المدير: ${s['director_name'] ?? '-'}'),
                      if (y != null)
                        Text('السنة: ${y.start} → ${y.end}'),
                    ],
                  ),
                ),
              ),
              if (ended.value ?? false)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    leading: const Icon(Icons.event_available),
                    title: const Text('انتهت السنة الدراسية'),
                    subtitle: const Text('اختر: إبقاء الأسماء وتصفير العدّاد، أو أرشفة، أو تصفير شامل'),
                    trailing: FilledButton(
                      onPressed: () => _yearEndOptions(context, ref),
                      child: const Text('الخيارات'),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              _TodayCard(
                today: _today,
                rowsStream: _todayRows,
                sessionsStream: _todaySessions,
                classesStream: _classes,
              ),
              const SizedBox(height: 8),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.5,
                children: <Widget>[
                  _Tile(
                    icon: Icons.class_,
                    label: 'الصفوف',
                    onTap: () => context.push('/classes'),
                  ),
                  _Tile(
                    icon: Icons.badge,
                    label: 'البادجات',
                    onTap: () => _openClassFlow(context, db, '/badges'),
                  ),
                  _Tile(
                    icon: Icons.qr_code_scanner,
                    label: 'مسح الحضور',
                    onTap: () => _openClassFlow(context, db, '/scan'),
                  ),
                  _Tile(
                    icon: Icons.fact_check,
                    label: 'كشف اليوم',
                    onTap: () => _openClassFlow(context, db, '/day-sheet'),
                  ),
                  _Tile(
                    icon: Icons.assessment,
                    label: 'التقارير',
                    onTap: () => context.push('/reports'),
                  ),
                  _Tile(
                    icon: Icons.download,
                    label: 'تصدير',
                    onTap: () => context.push('/export'),
                  ),
                  _Tile(
                    icon: Icons.beach_access,
                    label: 'الإجازات',
                    onTap: () => context.push('/leaves'),
                  ),
                  _Tile(
                    icon: Icons.event_repeat,
                    label: 'السنوات',
                    onTap: () => _openPin(context, ref, '/years'),
                  ),
                  _Tile(
                    icon: Icons.settings,
                    label: 'الإعدادات',
                    onTap: () => _openPin(context, ref, '/settings'),
                  ),
                  _Tile(
                    icon: Icons.info,
                    label: 'حول التطبيق',
                    onTap: () => _push(context, '/about'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// حالة جلسات اليوم لكل الصفوف: مسجل/الكل ومفتوحة/مقفلة + دخول مباشر.
///
/// كل تدفق هنا له حالة خطأ ظاهرة ([StreamGuard]) — لا «لا صفوف بعد» كاذبة عند
/// فشل قاعدة البيانات.
class _TodayCard extends StatelessWidget {
  const _TodayCard({
    required this.today,
    required this.rowsStream,
    required this.sessionsStream,
    required this.classesStream,
  });

  final String today;
  final Stream<List<AttendanceRow>> rowsStream;
  final Stream<List<Session>> sessionsStream;
  final Stream<List<SchoolClass>> classesStream;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'جلسات اليوم $today',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              StreamGuard<List<SchoolClass>>(
                stream: classesStream,
                loading: const Padding(
                  padding: EdgeInsets.all(8),
                  child: LinearProgressIndicator(),
                ),
                builder: (BuildContext context, List<SchoolClass> classes) {
                  if (classes.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('لا صفوف بعد — أضف صفاً من شاشة الصفوف'),
                    );
                  }
                  return StreamGuard<List<Session>>(
                    stream: sessionsStream,
                    loading: const Padding(
                      padding: EdgeInsets.all(8),
                      child: LinearProgressIndicator(),
                    ),
                    builder: (BuildContext context, List<Session> sessions) {
                      final Map<int, Session> byClass = <int, Session>{
                        for (final Session s in sessions) s.classId: s,
                      };
                      return StreamGuard<List<AttendanceRow>>(
                        stream: rowsStream,
                        loading: const Padding(
                          padding: EdgeInsets.all(8),
                          child: LinearProgressIndicator(),
                        ),
                        builder: (
                          BuildContext context,
                          List<AttendanceRow> rows,
                        ) {
                          final Map<int, int> counted = <int, int>{};
                          for (final AttendanceRow r in rows) {
                            if (r.status == AttendanceStatus.present ||
                                r.status == AttendanceStatus.late ||
                                r.status == AttendanceStatus.leave) {
                              counted[r.classId] =
                                  (counted[r.classId] ?? 0) + 1;
                            }
                          }
                          return Column(
                            children: <Widget>[
                              for (final SchoolClass c in classes)
                                _ClassDayTile(
                                  today: today,
                                  schoolClass: c,
                                  recorded: counted[c.id] ?? 0,
                                  session: byClass[c.id],
                                ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      );
}

/// صف واحد في بطاقة اليوم بسطر واحد (الاسم + المسجل + الحالة)
/// + دخول مباشر لكشف يومه.
class _ClassDayTile extends StatelessWidget {
  const _ClassDayTile({
    required this.today,
    required this.schoolClass,
    required this.recorded,
    required this.session,
  });

  final String today;
  final SchoolClass schoolClass;
  final int recorded;
  final Session? session;

  @override
  Widget build(BuildContext context) {
    final String title = '${schoolClass.grade} ـ ${schoolClass.section}';
    final Session? s = session;
    final String state = s == null
        ? 'لم تُفتح جلسة'
        : (s.closedAt != null ? 'مقفلة' : 'مفتوحة');
    return ListTile(
      dense: true,
      title: Text(
        '$title • مسجل: $recorded • $state',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_left),
      onTap: () => context.push(
        AppRoutes.classLocation(
          '/day-sheet',
          schoolClass.id,
          title,
          date: today,
        ),
        extra: ClassRef(id: schoolClass.id, title: title),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 36),
              const SizedBox(height: 6),
              Text(label, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
      );
}
