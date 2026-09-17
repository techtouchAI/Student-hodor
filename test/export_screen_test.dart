/// اختبارات منطق شاشة التصدير الخالص (بلا مضيف ودجت):
/// حارس «قسم واحد على الأقل» يمنع بناء ملف بلا محتوى.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/features/export/export_screen.dart';

void main() {
  group('exportHasContent', () {
    test('إكسل: أي قسم يكفي، وانعدام الكل مرفوض', () {
      expect(
        exportHasContent(
          format: ExportFormat.excel,
          daily: false,
          summary: false,
          leaves: false,
        ),
        isFalse,
      );
      expect(
        exportHasContent(
          format: ExportFormat.excel,
          daily: true,
          summary: false,
          leaves: false,
        ),
        isTrue,
      );
      expect(
        exportHasContent(
          format: ExportFormat.excel,
          daily: false,
          summary: false,
          leaves: true,
        ),
        isTrue,
      );
    });

    test('PDF: الإجازات ليست قسماً (خاصة بإكسل)', () {
      expect(
        exportHasContent(
          format: ExportFormat.pdf,
          daily: false,
          summary: true,
          leaves: false,
        ),
        isTrue,
      );
      expect(
        exportHasContent(
          format: ExportFormat.pdf,
          daily: false,
          summary: false,
          leaves: true,
        ),
        isFalse,
      );
      expect(
        exportHasContent(
          format: ExportFormat.pdf,
          daily: false,
          summary: false,
          leaves: false,
        ),
        isFalse,
      );
    });
  });
}
