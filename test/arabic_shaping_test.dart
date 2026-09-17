import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/arabic_shaping.dart';

void main() {
  test('تشكيل سياقي: محمد', () {
    expect(reshapeArabic('محمد'), '\uFEE3\uFEA4\uFEE4\uFEAA');
  });

  test('لام-ألف نهائية بعد حرف متصل: سلام', () {
    // س ابتدائية + لام-ألف نهائية + م معزولة (الألف لا تصل بما بعدها)
    expect(reshapeArabic('سلام'), '\uFEB3\uFEFC\uFEE1');
  });

  test('لام-ألف معزولة في بداية الكلمة: لام', () {
    expect(reshapeArabic('لام'), '\uFEFB\uFEE1');
  });

  test('حروف لا تتصل بما بعدها: أداء', () {
    // أ (نهائي بعد لا شيء => معزول) د (معزول) ا (معزول) ء معزول
    expect(reshapeArabic('أد'), '\uFE83\uFEA9');
  });

  test('التشكيل يُحذف افتراضياً ويبقى اختيارياً', () {
    expect(reshapeArabic('عِلْم'), reshapeArabic('علم'));
    expect(
      reshapeArabic('عِلْم', deleteHarakat: false).length,
      greaterThan(reshapeArabic('عِلْم').length),
    );
  });

  test('الترتيب البصري يبقي الأرقام متسلسلة ويضعها بموضعها', () {
    final String visual = toVisualOrder(reshapeArabic('كتاب 12'));
    expect(visual.startsWith('12'), isTrue);
    expect(visual, isNot(contains('21')));
  });

  test('نص لاتيني داخل سياق عربي لا ينكسر', () {
    final String visual = toVisualOrder(reshapeArabic('صف B2'));
    expect(visual.contains('B2'), isTrue);
  });

  test('arabicForPdf لا يرمي على نص فارغ أو أرقام فقط', () {
    expect(arabicForPdf(''), '');
    expect(arabicForPdf('123'), '123');
  });

  test('التطويل يُحفَظ: فاصل الصف «السادس ـ أ» لا يتحول لفراغ مزدوج', () {
    expect(reshapeArabic('السادس ـ أ'), contains('ـ'));
    expect(arabicForPdf('السادس ـ أ'), contains('ـ'));
  });

  test('الأقواس حول عربية تُعكَس صورها وتبقى بموضعها', () {
    final String visual = arabicForPdf('(ملاحظة)');
    expect(visual.startsWith('('), isTrue);
    expect(visual.endsWith(')'), isTrue);
  });

  test('نص لاتيني خالص بأقواس يُترَك كما هو', () {
    expect(arabicForPdf('Class (A)'), 'Class (A)');
    expect(arabicForPdf('HD-2026-0001'), 'HD-2026-0001');
  });

  test('زوج أقواس يحوي خليطاً لا ينكسر ولا تُقلَب محتوياته', () {
    final String visual =
        arabicForPdf('السنة: 2026 (2026-01-01 إلى 2026-06-30)');
    expect(visual, contains('2026-01-01'));
    expect(visual, contains('2026-06-30'));
    expect('('.allMatches(visual).length, 1);
    expect(')'.allMatches(visual).length, 1);
  });

  test('لا فراغ مضاعف حول الأرقام داخل السياق العربي', () {
    // المحايد كان يلتصق بالمقطع الحالي من الطرفين فيتكدس فراغان.
    expect(arabicForPdf('مدرسة 2 الابتدائية'), isNot(contains('  ')));
    expect(
      arabicForPdf('السنة الدراسية: 2026-2027 (2026-09-01 إلى 2027-06-30)'),
      isNot(contains('  ')),
    );
  });

  test('عبارة لاتينية داخل عربية تبقى كتلة واحدة لا تنعكس كلماتها', () {
    final String visual = arabicForPdf('ملف Hello World نهاية');
    expect(visual, contains('Hello World'));
  });

  test('ملتصقات الأرقام لا تنفصل: النسبة مع رقمها والسالب معه', () {
    expect(arabicForPdf('نسبة الحضور 100%'), contains('100%'));
    expect(arabicForPdf('خصم 50% (لفترة محدودة)'), contains('50%'));
    expect(arabicForPdf('الرصيد -5 دنانير'), contains('-5'));
  });

  test('أشكال التقديم مطابقة ليونيكود: كل حرف بشكله المعزول الصحيح', () {
    // قيم مرجعية من معيار يونيكود (Forms-B) لا من جدول الكود — إزاحة
    // سابقة كانت تعرض الحرف التالي (ف→ق، م→ن...) والياء كلام-ألف.
    const Map<String, int> isolated = <String, int>{
      'ء': 0xFE80, 'آ': 0xFE81, 'أ': 0xFE83, 'ؤ': 0xFE85, 'إ': 0xFE87,
      'ئ': 0xFE89, 'ا': 0xFE8D, 'ب': 0xFE8F, 'ة': 0xFE93, 'ت': 0xFE95,
      'ث': 0xFE99, 'ج': 0xFE9D, 'ح': 0xFEA1, 'خ': 0xFEA5, 'د': 0xFEA9,
      'ذ': 0xFEAB, 'ر': 0xFEAD, 'ز': 0xFEAF, 'س': 0xFEB1, 'ش': 0xFEB5,
      'ص': 0xFEB9, 'ض': 0xFEBD, 'ط': 0xFEC1, 'ظ': 0xFEC5, 'ع': 0xFEC9,
      'غ': 0xFECD, 'ـ': 0x0640, 'ف': 0xFED1, 'ق': 0xFED5, 'ك': 0xFED9,
      'ل': 0xFEDD, 'م': 0xFEE1, 'ن': 0xFEE5, 'ه': 0xFEE9, 'و': 0xFEED,
      'ى': 0xFEEF, 'ي': 0xFEF1,
    };
    isolated.forEach((String ch, int form) {
      expect(reshapeArabic(ch).runes.toList(), <int>[form], reason: ch);
    });
  });

  test('كلمات ذهبية بأشكال مواضعها الصحيحة (ابتدائي/وسطي/نهائي)', () {
    expect(
      arabicForPdf('مدرسة').runes.toList(),
      <int>[0xFE94, 0xFEB3, 0xFEAD, 0xFEAA, 0xFEE3],
    );
    expect(
      arabicForPdf('يفتح').runes.toList(),
      <int>[0xFEA2, 0xFE98, 0xFED4, 0xFEF3],
    );
  });

  test('لام-ألف وحدها صاحبة النطاق FEF5-FEFC لا الياء', () {
    expect(reshapeArabic('لا'), '\uFEFB');
    expect(reshapeArabic('لأ'), '\uFEF7');
    expect(reshapeArabic('ي'), '\uFEF1');
  });
}
