/// جذر التطبيق: سمة عربية RTL + راوتر.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/badges/badges_screen.dart';
import 'features/classes/classes_screen.dart';
import 'features/export/export_screen.dart';
import 'features/home/home_screen.dart';
import 'features/leaves/leaves_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/scan/scan_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/students/students_screen.dart';
import 'features/years/years_screen.dart';
import 'state/providers.dart';

final GoRouter router = GoRouter(
  initialLocation: '/',
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
        classId: int.parse(st.uri.queryParameters['class'] ?? '0'),
        title: Uri.decodeComponent(st.uri.queryParameters['title'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/badges',
      builder: (_, GoRouterState st) => BadgesScreen(
        classId: int.parse(st.uri.queryParameters['class'] ?? '0'),
        title: Uri.decodeComponent(st.uri.queryParameters['title'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/scan',
      builder: (_, GoRouterState st) => ScanScreen(
        classId: int.parse(st.uri.queryParameters['class'] ?? '0'),
        title: Uri.decodeComponent(st.uri.queryParameters['title'] ?? ''),
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
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'Tajawal',
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0D6E5F)),
          scaffoldBackgroundColor: const Color(0xFFF6F8F7),
        ),
        // فرض الاتجاه RTL لكل الشاشات بدون اعتماد ترجمة المواد.
        builder: (BuildContext context, Widget? child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
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
        Future<void>(() =>
            context.go(configured ? '/home' : '/onboarding'));
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
    );
  }
}
