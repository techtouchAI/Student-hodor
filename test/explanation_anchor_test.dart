import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/explanation.dart';

/// اختبار واجهة: زر التوضيح يعرض النص **الكامل** في حوار عند الضغط —
/// حل مشكلة التوضيحات المقطوعة أو المخفية على الشاشة الضيقة.
void main() {
  testWidgets(
    'ضغط زر التوضيح يعرض النص الكامل، والإغلاق يعود للشاشة',
    (WidgetTester tester) async {
      const String text =
          'شرح كامل طويل يتجاوز سطراً واحداً ليتأكد أنه يُعرض '
          'بلا قطع عند فتح الحوار من أي صفحة.';
      await tester.pumpWidget(
        const Scaffold(body: Center(child: ExplanationAnchor(text: text))),
      );

      await tester.tap(find.byType(ExplanationAnchor));
      await tester.pumpAndSettle();

      expect(find.text('توضيح'), findsOneWidget, reason: 'عنوان الحوار');
      expect(find.text(text), findsOneWidget,
          reason: 'النص الكامل يظهر في الحوار بلا قطع',);

      await tester.tap(find.text('إغلاق'));
      await tester.pumpAndSettle();
      expect(find.text('توضيح'), findsNothing, reason: 'الحوار يُغلق');
    },
  );
}
