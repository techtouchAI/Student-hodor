/// عنصر توضيح عالمي: أيقونة مساعدة ضغطُها يفتح حوارًا يعرض النص **كاملاً**.
///
/// يعالج مشكلة التوضيحات المقطوعة أو المخفية على الشاشة الضيقة: الـ
/// `subtitle`/`helperText`/`Tooltip` قد لا يتسع السطر لها فتُقطَّع أو تُخفى،
/// بينما ضغط عنصر التوضيح يظهر الشرح كاملاً في أي صفحة كانت.
library;

import 'package:flutter/material.dart';

/// زر توضيح داخلي: يُوضع عادة بجوار بند أو نص قصير، وضغطُه يعرض التوضيح
/// الكامل في حوار. لا يعتمد على طول السطر المعروض، لذا لا تُقطَّع النصوص.
class ExplanationAnchor extends StatelessWidget {
  const ExplanationAnchor({
    super.key,
    required this.text,
    this.icon = Icons.help_outline,
    this.tooltip = 'توضيح',
    this.color,
    this.visualDensity = IconButtonVisualDensity.compact,
  });

  /// التوضيح الكامل الذي يظهر عند الضغط.
  final String text;

  /// الأيقونة (أيقونة مساعدة افتراضية).
  final IconData icon;

  /// نص الـ tooltip (تلميح قصير، لا يُعتمد عليه في إظهار التوضيح).
  final String tooltip;

  final Color? color;
  final IconButtonVisualDensity visualDensity;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, color: color),
        tooltip: tooltip,
        visualDensity: visualDensity,
        onPressed: () => showExplanation(context, text),
      );

  /// يفتح حوارًا يعرض [text] كاملاً. قابل للاستدعاء من أي صفحة.
  static Future<void> showExplanation(BuildContext context, String text) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('توضيح'),
        content: SingleChildScrollView(
          child: Text(
            text,
            textAlign: TextAlign.start,
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }
}
