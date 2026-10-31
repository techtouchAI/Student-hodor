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

    test('سجل الحصص التفصيلي قسم كافٍ في الصيغتين', () {
      expect(
        exportHasContent(
          format: ExportFormat.excel,
          daily: false,
          summary: false,
          leaves: false,
          lessonLog: true,
        ),
        isTrue,
      );
      expect(
        exportHasContent(
          format: ExportFormat.pdf,
          daily: false,
          summary: false,
          leaves: false,
          lessonLog: true,
        ),
        isTrue,
      );
    });

    test('سجل الحصص وحده كافٍ في Excel وPDF (انحدار: زر التوليد)', () {
      for (final ExportFormat format in ExportFormat.values) {
        expect(
          exportHasContent(
            format: format,
            daily: false,
            summary: false,
            leaves: false,
            absences: false,
            lessonLog: true,
          ),
          isTrue,
          reason: 'سجل الحصص قسم مستقل صالح في $format',
        );
      }
    });

    test('سجل الحصص مع قسم آخر يبقى صالحاً، ولا اختيار يُرفض في الصيغتين', () {
      for (final ExportFormat format in ExportFormat.values) {
        expect(
          exportHasContent(
            format: format,
            daily: false,
            summary: false,
            leaves: false,
            absences: true,
            lessonLog: true,
          ),
          isTrue,
          reason: 'سجل الحصص + الغيابات',
        );
        expect(
          exportHasContent(
            format: format,
            daily: true,
            summary: true,
            leaves: true,
            absences: true,
            lessonLog: true,
          ),
          isTrue,
          reason: 'جميع الأقسام',
        );
        expect(
          exportHasContent(
            format: format,
            daily: false,
            summary: false,
            leaves: false,
            absences: false,
            lessonLog: false,
          ),
          isFalse,
          reason: 'لا اختيار لأي قسم في $format',
        );
      }
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
        reason: 'ورقة الإجازات خاصة بإكسل',
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
        isTrue,
        reason: 'الغيابات فقط قسم صالح في الصيغتين إكسل وPDF',
      );
    });
  });
}
