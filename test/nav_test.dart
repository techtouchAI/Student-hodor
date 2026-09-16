import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/nav.dart';

void main() {
  group('بناء روابط الصفوف', () {
    test('العنوان العربي يُرمَّز مرة واحدة ويُفكّ مرة واحدة', () {
      final String loc =
          AppRoutes.classLocation('/students', 7, 'السادس ـ أ');
      final Uri uri = Uri.parse(loc);
      expect(uri.path, '/students');
      // go_router يفكّ الترميز عبر state.uri.queryParameters — مثلما هنا تماماً.
      expect(uri.queryParameters['class'], '7');
      expect(uri.queryParameters['title'], 'السادس ـ أ');
    });

    test('الرابط يبقى صالحاً مع % و + و & و = في الاسم', () {
      final String loc = AppRoutes.classLocation(
        '/badges',
        3,
        '50% أ+ب & ج = د',
      );
      final Uri uri = Uri.parse(loc);
      expect(uri.queryParameters['class'], '3');
      expect(uri.queryParameters['title'], '50% أ+ب & ج = د');
      // لا فكّ ترميز مزدوجاً: القيمة لا تحوي %25 بعد فكّ واحد.
      expect(uri.queryParameters['title']!.contains('%25'), isFalse);
    });

    test('التاريخ يُمرَّر لكشف اليوم', () {
      final String loc = AppRoutes.classLocation(
        '/day-sheet',
        1,
        'الأول ـ أ',
        date: '2026-09-13',
      );
      expect(Uri.parse(loc).queryParameters['date'], '2026-09-13');
    });

    test('لا معامل تاريخ فارغ', () {
      final String loc =
          AppRoutes.classLocation('/day-sheet', 1, 'الأول ـ أ', date: '');
      expect(Uri.parse(loc).queryParameters.containsKey('date'), isFalse);
    });
  });

  group('ClassRef', () {
    test('displayTitle لا يكون فارغاً أبداً', () {
      expect(const ClassRef(id: 1).displayTitle, 'الصف');
      expect(const ClassRef(id: 1, title: '  ').displayTitle, 'الصف');
      expect(const ClassRef(id: 1, title: ' السادس ـ أ ').displayTitle,
          'السادس ـ أ');
    });
  });
}
