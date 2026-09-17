/// شاشة «حول التطبيق»: بطاقة تعريف بمطوّر التطبيق وروابط التواصل
/// (يوتيوب/تيليجرام).
///
/// استُبدلت بها شاشة «التشخيص وسجل الأعطال» بطلب المطوّر: الصفحة أصبحت
/// بطاقة تعريف وروابط تواصل، ولم يعد سجل الأعطال معروضاً عليها.
/// (آلية تسجيل الأعطال نفسها في `core/error_guard.dart` و`data/error_log.dart`
/// تعمل كما كانت.)
library;

import 'package:flutter/material.dart';

import '../../core/app_links.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String _developerAr = 'كنان الصائغ';
  static const String _developerEn = 'Kinan Al-Sayegh';
  static const String _youtubeUrl =
      'https://youtube.com/@kinanmajeed?si=I2yuzJT2rRnEHLVg';
  static const String _telegramUrl = 'https://t.me/techtouch7';

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('حول مطور التطبيق')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: <Widget>[
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.person,
                      size: 42,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('المطور', style: tt.labelLarge),
                  const SizedBox(height: 4),
                  Text(
                    _developerAr,
                    style: tt.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(_developerEn, style: tt.titleSmall),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: cs.secondaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'التطبيق حاليًا مجاني - نسخة تجريبية',
                      style: TextStyle(color: cs.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('للتواصل', style: tt.titleLarge),
          const SizedBox(height: 8),
          const _ContactTile(
            // لا أيقونة «يوتيوب» ضمن Material Icons المضمّنة: سهم تشغيل
            // داخل الدائرة الحمراء هو العلامة البصرية المعتمدة هنا.
            icon: Icons.play_arrow,
            color: Color(0xFFFF0000),
            label: 'يوتيوب',
            subtitle: '@kinanmajeed',
            url: _youtubeUrl,
          ),
          const SizedBox(height: 8),
          const _ContactTile(
            icon: Icons.send_rounded,
            color: Color(0xFF26A5E4),
            label: 'تيليجرام',
            subtitle: '@techtouch7',
            url: _telegramUrl,
          ),
        ],
      ),
    );
  }
}

/// أيقونة تواصل واحدة: دائرة بلون العلامة مع رمز واضح، وبالضغط عليها
/// يُفتح الرابط في التطبيق/المتصفح المناسب.
class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.subtitle,
    required this.url,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String subtitle;
  final String url;

  Future<void> _open(BuildContext context) async {
    final bool opened = await AppLinks.open(url);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر فتح التطبيق — انسخ الرابط: $url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          onTap: () => _open(context),
          leading: CircleAvatar(
            radius: 24,
            backgroundColor: color,
            child: Icon(icon, color: Colors.white, size: 30),
          ),
          title: Text(label),
          subtitle: Text(subtitle),
          trailing: Icon(
            Icons.open_in_new,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
}
