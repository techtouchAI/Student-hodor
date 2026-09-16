/// مساعدو التنقّل: معرّفات الصفوف تُمرَّر عبر `Uri(queryParameters:)` لا عبر
/// تركيب نصي يدوي.
///
/// العلّة التي كانت تكسر الشاشات الأربع (طلاب/بادجات/مسح/كشف اليوم):
/// 1. الروابط كانت تُبنى بدمج نصوص مع `Uri.encodeComponent`، و`go_router` يفكّ
///    الترميز مرة أخرى ⇒ **فكّ ترميز مزدوج** يرمي `FormatException` أو يعيد
///    `class=0` فتُفتح الشاشة بلا صف.
/// 2. أي استثناء داخل `builder` المسار كان يُسقط بناء الراوتر كله ⇒ صفحة بيضاء.
///
/// القاعدة الآن: الترميز يترك لـ`Uri`، والقراءة من `state.uri.queryParameters`
/// **دون** `Uri.decodeComponent`، وكل شاشة تحلّ صفها من قاعدة البيانات إن غاب
/// المعرّف (انظر `AppDb.resolveClassRef`).
library;

import 'package:go_router/go_router.dart';

/// مرجع صف للتنقّل: معرّف + عنوان جاهز للعرض (قد يُمرَّر عبر `extra`).
class ClassRef {
  const ClassRef({required this.id, this.title = ''});

  final int id;
  final String title;

  /// عنوان للعرض لا يكون فارغاً أبداً.
  String get displayTitle => title.trim().isEmpty ? 'الصف' : title.trim();

  @override
  String toString() => 'ClassRef($id, $title)';
}

/// أسماء المسارات — تُستخدم مع `pushNamed` فيتولّى `go_router` الترميز.
class AppRoutes {
  const AppRoutes._();

  static const String home = 'home';
  static const String classes = 'classes';
  static const String students = 'students';
  static const String badges = 'badges';
  static const String scan = 'scan';
  static const String daySheet = 'daySheet';
  static const String student = 'student';
  static const String reports = 'reports';
  static const String export = 'export';
  static const String leaves = 'leaves';
  static const String years = 'years';
  static const String settings = 'settings';
  static const String diagnostics = 'diagnostics';

  /// رابط صف مبني بترميز صحيح (يُستخدم عند الحاجة لرابط نصي).
  static String classLocation(
    String path,
    int classId,
    String title, {
    String? date,
  }) =>
      Uri(
        path: path,
        queryParameters: <String, String>{
          'class': '$classId',
          if (title.isNotEmpty) 'title': title,
          if (date != null && date.isNotEmpty) 'date': date,
        },
      ).toString();
}

/// قراءة آمنة لمعرّف الصف من حالة المسار (بلا فكّ ترميز مزدوج).
int classIdOf(GoRouterState state) =>
    int.tryParse(state.uri.queryParameters['class'] ?? '') ?? 0;

/// قراءة آمنة لعنوان الصف: `go_router` فكّ الترميز مسبقاً، ونعيد المحاولة مرة
/// واحدة فقط إن وصلت القيمة ما زالت مرمّزة (روابط خارجية/استعادة عملية).
String titleOf(GoRouterState state) =>
    _safeDecode(state.uri.queryParameters['title'] ?? '');

String _safeDecode(String raw) {
  if (!raw.contains('%')) {
    return raw;
  }
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

/// تاريخ كشف اليوم (اختياري) — يُترك فارغاً لتحلّه الشاشة بيومها.
String dateOf(GoRouterState state) => state.uri.queryParameters['date'] ?? '';

/// مرجع صف من حالة المسار + `extra` (الأولوية لـ`extra` لأنه بلا ترميز إطلاقاً).
ClassRef classRefOf(GoRouterState state) {
  final Object? extra = state.extra;
  if (extra is ClassRef && extra.id > 0) {
    return extra;
  }
  return ClassRef(id: classIdOf(state), title: titleOf(state));
}
