/// جذر التطبيق: سمة عربية RTL + راوتر.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/home/home_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'state/providers.dart';

final GoRouter router = GoRouter(
  initialLocation: '/',
  routes: <GoRoute>[
    GoRoute(path: '/', builder: (_, __) => const _SplashGate()),
    GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
    GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
  ],
);

class StudentHodorApp extends ConsumerWidget {
  const StudentHodorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
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
