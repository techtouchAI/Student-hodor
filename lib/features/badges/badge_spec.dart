/// مواصفة الباج الموحّدة: مصدر حقيقة واحد لشاشتي العرض والطباعة.
library;

import 'dart:typed_data';
import 'dart:ui';

class BadgePalette {
  const BadgePalette._();
  static const Color header = Color(0xFF0D6E5F);
  static const Color headerDark = Color(0xFF084C41);
  static const Color gold = Color(0xFFC9A227);
  static const Color background = Color(0xFFFAFAF8);
  static const Color ink = Color(0xFF1B1B1B);
}

/// أبعاد الباج: CR80 عمودي (54×86 مم) بالنسبة نفسها على الشاشة والطباعة.
class BadgeMetrics {
  const BadgeMetrics._();
  static const double widthMm = 54;
  static const double heightMm = 86;

  /// نقطة (pt) = 1/72 إنش؛ مم = 72/25.4 pt.
  static double get widthPt => widthMm * 72 / 25.4;
  static double get heightPt => heightMm * 72 / 25.4;
}

class BadgeSpec {
  const BadgeSpec({
    required this.schoolName,
    required this.directorName,
    required this.studentName,
    required this.grade,
    required this.section,
    required this.yearName,
    required this.code,
    required this.sequence,
    this.photoBytes,
    this.phone,
  });

  final String schoolName;
  final String directorName;
  final String studentName;
  final String grade;
  final String section;
  final String yearName;
  final String code;
  final int sequence;
  final List<int>? photoBytes;
  final String? phone;

  String get classLine => 'الصف: $grade ـ $section';
  String get yearLine => 'العام الدراسي: $yearName';
  String get seqLine => 'رقم الطالب: ${sequence.toString().padLeft(4, '0')}';

  /// سطر الهاتف دائم الظهور على الباج: الرقم إن وُجد، وإلا فراغ مخصص
  /// بعرض 11 رقماً (11 شرطة سفلية) يُكتب فيه يدوياً بعد الطباعة.
  String get phoneLine {
    final String? p = phone;
    final String digits =
        (p == null || p.isEmpty) ? '_' * 11 : p;
    return 'الهاتف: $digits';
  }

  /// يتحقق أن بايتات الصورة قابلة للفك فعلاً قبل إدخالها في الباج.
  ///
  /// ملف موجود لكن محتواه تالف كان يمرّ من هنا ثم يُسقط حفظ PDF كله،
  /// لأن الفك في حزمة pdf كسول يتم لحظة الحفظ لا لحظة البناء. التالف
  /// يُعاد عنه `null` (فيظهر مربع الحرف الأول) ويُسجَّل في سجل الأخطاء
  /// بدل إسقاط ورقة البادجات.
  static Future<Uint8List?> validPhotoBytes(List<int> bytes) async {
    final Uint8List raw =
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    try {
      final Codec codec = await instantiateImageCodec(raw);
      codec.dispose();
      return raw;
    } catch (_) {
      return null;
    }
  }
}
