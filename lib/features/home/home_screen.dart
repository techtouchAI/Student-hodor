/// الشاشة الرئيسة: بطاقة المدرسة/اليوم + شبكة الوحدات + بوابة PIN.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../state/providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<(int, String)?> _pickClass(BuildContext context, AppDb db) async {
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return null;
    }
    final List<SchoolClass> classes =
        await (db.select(db.schoolClasses)..where((c) => c.yearId.equals(year.id)))
            .get();
    if (!context.mounted) {
      return null;
    }
    return showDialog<(int, String)>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('اختر صفاً'),
        children: <Widget>[
          if (classes.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('لا صفوف — أضف من شاشة الصفوف'),
            ),
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

  Future<void> _openPin(BuildContext context, WidgetRef ref, String route) async {
    final String? pin = await ref.read(dbProvider).setting('pin');
    if (pin == null || pin.isEmpty || ref.read(pinUnlockedProvider)) {
      context.go(route);
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
    if (entered == pin) {
      ref.read(pinUnlockedProvider.notifier).state = true;
      context.go(route);
    } else if (entered != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('رمز غير صحيح')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppDb db = ref.watch(dbProvider);
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
                      Text('المدير: ${s['director_name'] ?? '-'}'),
                      if (y != null)
                        Text('السنة: ${y.name} (${y.start} → ${y.end})'),
                      Text(
                        'اليوم: ${SchoolTime.formatFullAr(DateTime.now(), withHijri: s['show_hijri'] == '1')}',
                      ),
                    ],
                  ),
                ),
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
                    onTap: () => context.go('/classes'),
                  ),
                  _Tile(
                    icon: Icons.badge,
                    label: 'البادجات',
                    onTap: () async {
                      final (int, String)? p = await _pickClass(context, db);
                      if (p != null && context.mounted) {
                        context.go('/badges?class=${p.$1}&title=${Uri.encodeComponent(p.$2)}');
                      }
                    },
                  ),
                  _Tile(
                    icon: Icons.qr_code_scanner,
                    label: 'مسح الحضور',
                    onTap: () async {
                      final (int, String)? p = await _pickClass(context, db);
                      if (p != null && context.mounted) {
                        context.go('/scan?class=${p.$1}&title=${Uri.encodeComponent(p.$2)}');
                      }
                    },
                  ),
                  _Tile(
                    icon: Icons.assessment,
                    label: 'التقارير',
                    onTap: () => context.go('/reports'),
                  ),
                  _Tile(
                    icon: Icons.download,
                    label: 'تصدير',
                    onTap: () => context.go('/export'),
                  ),
                  _Tile(
                    icon: Icons.beach_access,
                    label: 'الإجازات',
                    onTap: () => context.go('/leaves'),
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
                ],
              ),
            ],
          ),
        ),
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
