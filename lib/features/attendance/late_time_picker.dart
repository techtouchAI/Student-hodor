/// منتقي وقت التأخر اليدوي — مشترك بين كشف اليوم وملف الطالب حتى يتطابق
/// سلوك «تسجيل متأخر يدوياً» في الشاشتين (ساعة ودقيقة تُثبّتان في السجل).
library;

import 'package:flutter/material.dart';

import '../../core/late_time.dart';

/// يسأل عن وقت وصول طالب سُجّل «متأخر» يدوياً.
///
/// يعيد الوقت بصيغة `HH:mm`، أو `null` إن اختار المستخدم ألا يحدد وقتاً —
/// فيُحفَظ التأخر بلا وقت بدل تعطيل التسجيل. الوقت المبدئي المقترح هو
/// الوقت الحالي لأن التأخر اليدوي غالباً تصحيحٌ لحظي.
Future<String?> pickManualArrivalTime(BuildContext context) async {
  final DateTime now = DateTime.now();
  final TimeOfDay? picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: now.hour, minute: now.minute),
    helpText: 'وقت وصول الطالب المتأخر (ساعة ودقيقة)',
  );
  if (picked == null) {
    return null;
  }
  return arrivalTimeString(DateTime(2000, 1, 1, picked.hour, picked.minute));
}
