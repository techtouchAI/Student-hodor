import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/arabic_shaping.dart';

void main() {
  test('تشكيل سياقي: محمد', () {
    expect(reshapeArabic('محمد'), '\uFEE7\uFEA4\uFEE8\uFEAA');
  });

  test('لام-ألف نهائية بعد حرف متصل: سلام', () {
    // س ابتدائية + لام-ألف نهائية + م معزولة (الألف لا تصل بما بعدها)
    expect(reshapeArabic('سلام'), '\uFEB3\uFEFC\uFEE5');
  });

  test('لام-ألف معزولة في بداية الكلمة: لام', () {
    expect(reshapeArabic('لام'), '\uFEFB\uFEE5');
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
}
