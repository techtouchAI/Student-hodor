/// جذر التطبيق: سمة عربية RTL + تعريب المواد + راوتر بمسارات كاملة.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/attendance/day_sheet_screen.dart';
import 'features/badges/badges_screen.dart';
import 'features/classes/classes_screen.dart';
import 'features/export/export_screen.dart';
import 'features/home/home_screen.dart';
import 'features/leaves/leaves_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/reports/student_report_screen.dart';
import 'features/scan/scan_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/students/students_screen.dart';
import 'features/years/years_screen.dart';
import 'state/providers.dart';

final GoRouter router = GoRouter(
  initialLocation: '/',
  errorBuilder: (BuildContext context, GoRouterState state) =>
      _RouteErrorScreen(uri: state.uri.toString()),
  routes: <GoRoute>[
    GoRoute(path: '/', builder: (_, __) => const _SplashGate()),
    GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
    GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
    GoRoute(path: '/classes', builder: (_, __) => const ClassesScreen()),
    GoRoute(path: '/leaves', builder: (_, __) => const LeavesScreen()),
    GoRoute(path: '/reports', builder: (_, __) => const ReportsScreen()),
    GoRoute(path: '/export', builder: (_, __) => const ExportScreen()),
    GoRoute(path: '/years', builder: (_, __) => const YearsScreen()),
    GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
    GoRoute(
      path: '/students',
      builder: (_, GoRouterState st) => StudentsScreen(
        classId: int.tryParse(st.uri.queryParameters['class'] ?? '') ?? 0,
        title: Uri.decodeComponent(st.uri.queryParameters['title'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/badges',
      builder: (_, GoRouterState st) => BadgesScreen(
        classId: int.tryParse(st.uri.queryParameters['class'] ?? '') ?? 0,
        title: Uri.decodeComponent(st.uri.queryParameters['title'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/scan',
      builder: (_, GoRouterState st) => ScanScreen(
        classId: int.tryParse(st.uri.queryParameters['class'] ?? '') ?? 0,
        title: Uri.decodeComponent(st.uri.queryParameters['title'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/day-sheet',
      builder: (_, GoRouterState st) => DaySheetScreen(
        classId: int.tryParse(st.uri.queryParameters['class'] ?? '') ?? 0,
        date: st.uri.queryParameters['date'] ?? '',
        title: Uri.decodeComponent(st.uri.queryParameters['title'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/student/:id',
      builder: (_, GoRouterState st) => StudentReportScreen(
        studentId: int.tryParse(st.pathParameters['id'] ?? '') ?? 0,
      ),
    ),
  ],
);

class StudentHodorApp extends ConsumerWidget {
  const StudentHodorApp({super.key});

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
          fontFamily: 'Tajawal',
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0D6E5F)),
          scaffoldBackgroundColor: const Color(0xFFF6F8F7),
        ),
        // فرض الاتجاه RTL لكل الشاشات بدون اعتماد ترجمة المواد.
        builder: (BuildContext context, Widget? child) => Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        ),
        routerConfig: router,
      );
}

/// يقرر الوجهة الأولى: إعداد أولي أم شاشة رئيسة.
class _SplashGate extends ConsumerWidget {
  const _SplashGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Map<String, String>> settings =
        ref.watch(settingsProvider);
    return settings.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (Object e, StackTrace st) => Scaffold(
        body: Center(child: Text('خطأ في فتح قاعدة البيانات: $e')),
      ),
      data: (Map<String, String> s) {
        final bool configured = (s['school_name'] ?? '').isNotEmpty;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            context.go(configured ? '/home' : '/onboarding');
          }
        });
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
    );
  }
}

/// صفحة خطأ موحّدة للمسارات غير الموجودة بدل ودجت الخطأ الخام.
class _RouteErrorScreen extends StatelessWidget {
  const _RouteErrorScreen({required this.uri});

  final String uri;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('صفحة غير موجودة')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.explore_off, size: 64),
                const SizedBox(height: 12),
                Text('لا يوجد مسار للعنوان: $uri'),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => context.go('/home'),
                  icon: const Icon(Icons.home),
                  label: const Text('العودة للرئيسة'),
                ),
              ],
            ),
          ),
        ),
      );
}
