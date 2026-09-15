/// رمز الباج: مفتاح ثابت قصير سهل المسح، لا يحمل بيانات شخصية.
///
/// الصيغة: SH-{رمز المدرسة 3}-{تسلسل 4}-{سنة 2}-{تحقق 1}
/// مثال: SH-K7M-0042-26-Q
/// التحقق: مجموع موزون لوحدات الرمز modulo 36 (يكشف أخطاء الإدخال/المسح).
library;

const String _alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

class BadgeCode {
  const BadgeCode._();

  static String _base36(int value, int width) =>
      value.toRadixString(36).toUpperCase().padLeft(width, '0');

  /// رمز مدرسة مشتق حتمياً من اسمها (3 خانات).
  static String schoolCode(String schoolName) {
    int hash = 0x811C9DC5;
    for (final int cp in schoolName.trim().runes) {
      hash ^= cp;
      hash = (hash * 0x01000193) & 0x7FFFFFFF;
    }
    return _base36(hash % (36 * 36 * 36), 3);
  }

  static int _checksum(String body) {
    int sum = 7;
    for (int i = 0; i < body.length; i++) {
      sum = (sum * 31 + body.codeUnitAt(i) * (i + 3)) & 0x7FFFFFFF;
    }
    return sum % 36;
  }

  /// يبني رمزاً كاملاً مع خانة التحقق.
  static String make({
    required String schoolName,
    required int sequence,
    required int yearShort,
  }) {
    final String body =
        'SH-${schoolCode(schoolName)}-${sequence.toString().padLeft(4, '0')}'
        '-${(yearShort % 100).toString().padLeft(2, '0')}';
    return '$body-${_alphabet[_checksum(body)]}';
  }

  /// يتحقق من صحة رمز ممسوح ويعيد مكوناته، أو null إن كان تالفاً/غريباً.
  static ParsedBadgeCode? parse(String raw) {
    final String code = raw.trim().toUpperCase();
    final RegExp pattern = RegExp(r'^SH-([A-Z0-9]{3})-(\d{4})-(\d{2})-([A-Z0-9])$');
    final RegExpMatch? m = pattern.firstMatch(code);
    if (m == null) {
      return null;
    }
    final String body = code.substring(0, code.length - 2);
    if (_alphabet[_checksum(body)] != m.group(4)) {
      return null;
    }
    return ParsedBadgeCode(
      code: code,
      schoolCode: m.group(1)!,
      sequence: int.parse(m.group(2)!),
      yearShort: int.parse(m.group(3)!),
    );
  }
}

class ParsedBadgeCode {
  const ParsedBadgeCode({
    required this.code,
    required this.schoolCode,
    required this.sequence,
    required this.yearShort,
  });

  final String code;
  final String schoolCode;
  final int sequence;
  final int yearShort;

  @override
  String toString() => code;
}
