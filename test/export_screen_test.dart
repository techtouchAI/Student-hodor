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

    test('إكسل: الغيابات وحدها قسم كافٍ', () {
      expect(
        exportHasContent(
          format: ExportFormat.excel,
          daily: false,
          summary: false,
          leaves: false,
          absences: true,
        ),
        isTrue,
      );
      expect(
        exportHasContent(
          format: ExportFormat.excel,
          daily: false,
          summary: false,
          leaves: false,
        ),
        isFalse,
        reason: 'بلا غيابات أيضاً يبقى انعدام الكل مرفوضاً',
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
      expect(
        exportHasContent(
          format: ExportFormat.pdf,
          daily: false,
          summary: false,
          leaves: false,
          absences: true,
        ),
        isFalse,
        reason: 'ورقة الغيابات خاصة بإكسل كالإجازات',
      );
    });
  });
}
