/// جذر التطبيق: سمة عربية RTL + تعريب المواد + راوتر بمسارات كاملة.
///
/// قاعدتان ثابتتان هنا:
/// - **لا معاملة روابط يدوية:** كل مسار يقرأ معاملاته عبر `core/nav.dart`.
/// - **لا صفحة بيضاء:** كل `builder` ملفوف بـ[ErrorBoundary]، وأي فشل في قراءة
///   المعاملات يُنتج شاشة خطأ مقروءة (`_RouteErrorScreen`) لا بياضاً.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/error_guard.dart';
import 'core/nav.dart';
import 'features/about/about_screen.dart';
import 'features/attendance/day_sheet_screen.dart';
import 'features/badges/badges_screen.dart';
import 'features/classes/classes_screen.dart';
import 'features/export/export_screen.dart';
import 'features/home/home_screen.dart';
import 'features/leaves/leaves_screen.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/notifications/notifications_watcher.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/reports/student_report_screen.dart';
import 'features/scan/scan_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/students/students_screen.dart';
import 'features/years/years_screen.dart';
import 'state/providers.dart';

/// يبني الراوتر. دالة (لا ثابت عام) حتى تُنشئ الاختبارات نسخة نظيفة لكل حالة.
GoRouter buildRouter() => GoRouter(
      initialLocation: '/',
      errorBuilder: (BuildContext context, GoRouterState state) =>
          _RouteErrorScreen(
        uri: state.uri.toString(),
        message: state.error?.toString(),
      ),
      routes: <GoRoute>[
        GoRoute(
          path: '/',
          builder: (_, __) => _guarded('splash', const _SplashGate()),
        ),
        GoRoute(
          path: '/onboarding',
          name: 'onboarding',
          builder: (_, __) => _guarded('onboarding', const OnboardingScreen()),
        ),
        GoRoute(
          path: '/home',
          name: AppRoutes.home,
          builder: (_, __) => _guarded('home', const HomeScreen()),
        ),
        GoRoute(
          path: '/classes',
          name: AppRoutes.classes,
          builder: (_, __) => _guarded('classes', const ClassesScreen()),
        ),
        GoRoute(
          path: '/leaves',
          name: AppRoutes.leaves,
          builder: (_, __) => _guarded('leaves', const LeavesScreen()),
        ),
        GoRoute(
          path: '/reports',
          name: AppRoutes.reports,
          builder: (_, __) => _guarded('reports', const ReportsScreen()),
        ),
        GoRoute(
          path: '/notifications',
          name: AppRoutes.notifications,
          builder: (_, __) =>
              _guarded('notifications', const NotificationsScreen()),
        ),
        GoRoute(
          path: '/export',
          name: AppRoutes.export,
          builder: (_, __) => _guarded('export', const ExportScreen()),
        ),
        GoRoute(
          path: '/years',
          name: AppRoutes.years,
          builder: (_, __) => _guarded('years', const YearsScreen()),
        ),
        GoRoute(
          path: '/settings',
          name: AppRoutes.settings,
          builder: (_, __) => _guarded('settings', const SettingsScreen()),
        ),
        GoRoute(
          path: '/about',
          name: AppRoutes.about,
          builder: (_, __) => _guarded('about', const AboutScreen()),
        ),
        GoRoute(
          path: '/students',
          name: AppRoutes.students,
          builder: (_, GoRouterState st) => _guarded(
            'students',
            StudentsScreen(classRef: _classRef(st)),
          ),
        ),
        GoRoute(
          path: '/badges',
          name: AppRoutes.badges,
          builder: (_, GoRouterState st) => _guarded(
            'badges',
            BadgesScreen(classRef: _classRef(st)),
          ),
        ),
        GoRoute(
          path: '/scan',
          name: AppRoutes.scan,
          builder: (_, GoRouterState st) => _guarded(
            'scan',
            ScanScreen(classRef: _classRef(st)),
          ),
        ),
        GoRoute(
          path: '/day-sheet',
          name: AppRoutes.daySheet,
          builder: (_, GoRouterState st) => _guarded(
            'daySheet',
            DaySheetScreen(classRef: _classRef(st), date: dateOf(st)),
          ),
        ),
        GoRoute(
          path: '/student/:id',
          name: AppRoutes.student,
          builder: (_, GoRouterState st) => _guarded(
            'student',
            StudentReportScreen(
              studentId: int.tryParse(st.pathParameters['id'] ?? '') ?? 0,
            ),
          ),
        ),
      ],
    );

/// قراءة مرجع الصف داخل `builder`: أي استثناء هنا كان يُسقط الراوتر كله
/// (صفحة بيضاء كاملة) — الآن يتحول إلى رسالة خطأ واضحة.
ClassRef _classRef(GoRouterState st) {
  try {
    return classRefOf(st);
  } catch (e) {
    return const ClassRef(id: 0);
  }
}

Widget _guarded(String label, Widget screen) =>
    ErrorBoundary(routeLabel: label, child: screen);

class StudentHodorApp extends ConsumerWidget {
  const StudentHodorApp({super.key, this.router});

  /// يُمرَّر في الاختبارات؛ الافتراضي راوتر التطبيق العام.
  final GoRouter? router;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
        title: 'حضور الطالب',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: const <Locale>[Locale('ar'), Locale('en')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'Amiri',
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0D6E5F)),
          scaffoldBackgroundColor: const Color(0xFFF6F8F7),
        ),
        // فرض الاتجاه RTL لكل الشاشات + حارس التنبيهات الجذري (مُركَّب فوق
        // كل المسارات: يمشي الاحتساب الحي وعمل الصلاحيات والروابط العميقة
        // بلا اعتماد على أي شاشة).
        builder: (BuildContext context, Widget? child) => Directionality(
          textDirection: TextDirection.rtl,
          child: NotificationsWatcher(
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        routerConfig: router ?? ref.read(appRouterProvider),
      );
}

/// يقرر الوجهة الأولى: إعداد أولي أم شاشة رئيسة.
///
/// ينتظر الإقلاع الأول اكتمال تهيئة طبقة الإشعارات ([initDone]) حتى لا
/// تفوت **نقرة إشعار نظام** أطلقت إقلاعًا باردًا (ترد بعد ذهاب/إياب قناة
/// المنصة). مؤقّت أمان (ثانيتان) يمنع الوقوف على الشاشة الافتتاحية أبدًا.
class _SplashGate extends ConsumerStatefulWidget {
  const _SplashGate();

  @override
  ConsumerState<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends ConsumerState<_SplashGate> {
  Timer? _fallback;

  @override
  void initState() {
    super.initState();
    // أمان: إن لم تكتمل تهيئة الإشعارات (عطل غير متوقع) نكمل الإقلاع.
    _fallback = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      ref.read(notificationInitDoneProvider.notifier).state = true;
    });
  }

  @override
  void dispose() {
    _fallback?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Map<String, String>> settings =
        ref.watch(settingsProvider);
    return settings.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (Object e, StackTrace st) => Scaffold(
        body: Center(child: LoadErrorCard(message: 'قاعدة البيانات: $e')),
      ),
      data: (Map<String, String> s) {
        final bool configured = (s['school_name'] ?? '').isNotEmpty;
        // المراقبة تجعل البناء يتجدد حين تصل الإشارة أو الرابط — ثم
        // يُقرأان مجددًا داخل الـ callback (قد يتغيران قبله).
        final bool initDone = ref.watch(notificationInitDoneProvider);
        final String? pending = ref.watch(pendingNotificationRouteProvider);
        if (initDone) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) {
              return;
            }
            // نقرة إشعار نظام أطلقت إقلاعًا باردًا: بعد تحميل الإعدادات
            // نذهب مباشرة إلى ملف الطالب لا إلى الرئيسية.
            final String? current =
                ref.read(pendingNotificationRouteProvider) ?? pending;
            ref.read(pendingNotificationRouteProvider.notifier).state = null;
            final String destination;
            if (configured && current != null) {
              destination = current;
            } else {
              destination = configured ? '/home' : '/onboarding';
            }
            context.go(destination);
          });
        }
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
    );
  }
}

/// صفحة خطأ موحّدة للمسارات غير الموجودة/المعاملات التالفة بدل ودجت الخطأ الخام.
class _RouteErrorScreen extends StatelessWidget {
  const _RouteErrorScreen({required this.uri, this.message});

  final String uri;
  final String? message;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('تعذر فتح الصفحة')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: <Widget>[
            const Icon(Icons.explore_off, size: 64),
            const SizedBox(height: 12),
            Text(
              message == null
                  ? 'لا يوجد مسار للعنوان: $uri'
                  : 'العنوان: $uri\nالسبب: $message',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Center(
              child: FilledButton.icon(
                onPressed: () => context.go('/home'),
                icon: const Icon(Icons.home),
                label: const Text('العودة للرئيسة'),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: OutlinedButton.icon(
                onPressed: () => context.pushNamed(AppRoutes.about),
                icon: const Icon(Icons.info),
                label: const Text('حول التطبيق'),
              ),
            ),
          ],
        ),
      );
}
