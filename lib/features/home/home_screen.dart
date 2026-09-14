/// الشاشة الرئيسة: بطاقة المدرسة/السنة + شبكة الوحدات.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../state/providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Map<String, String>> settings =
        ref.watch(settingsProvider);
    final AsyncValue<AcademicYear?> year = ref.watch(currentYearProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('حضور الطالب')),
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
                      const SizedBox(height: 4),
                      Text('المدير: ${s['director_name'] ?? '-'}'),
                      if (y != null)
                        Text(
                          'السنة الدراسية: ${y.name} '
                          '(${y.start} → ${y.end})',
                        ),
                      Text(
                        'اليوم: ${SchoolTime.formatFullAr(DateTime.now(), withHijri: s['show_hijri'] == '1')}',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'الوحدات (صفوف، طلاب، بادجات، مسح، تقارير، تصدير، سنوات، '
                    'إعدادات) تُبنى تباعاً فوق هذا الأساس.',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
