/// مواصفة الباج الموحّدة: مصدر حقيقة واحد لشاشتي العرض والطباعة.
library;

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

  String get classLine => 'الصف: $grade ـ $section';
  String get yearLine => 'العام الدراسي: $yearName';
  String get seqLine => 'رقم الطالب: ${sequence.toString().padLeft(4, '0')}';
}
