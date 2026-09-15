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
}
