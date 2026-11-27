/// الجسر الأصلي لجدولة الإقفال: يدفع مهمات الإقفال إلى Kotlin (AlarmManager).
///
/// يُفصل عن خدمة الجدولة (`data/closure_scheduler.dart`) لكي لا يحمل طبقة
/// البيانات اعتماداً على واجهات Flutter: الخدمة تُعرَّف بجسر عام، والتنفيذ
/// الأصلي يُمرَّر عند الإنشاء. أي عطل (منصة غير أندرويد، أو عدم توفر
/// المهمة الأصلية) يُهمَل: جدولة التنبيهات وسيلة تسريع، وليس مصدر
/// الحقيقة — الاسترداد من القاعدة عند التشغيل هو الضمانة.
library;

import 'package:flutter/services.dart';

import '../data/closure_scheduler.dart';

class MethodChannelClosureBridge implements NativeClosureBridge {
  const MethodChannelClosureBridge(this.channelName);

  final String channelName;

  static const String closureChannel = 'iq.techtouch.student_hodor.closure';

  @override
  Future<void> arm(List<ClosureArmedTask> tasks) async {
    try {
      await _channel.invokeMethod<void>(
        'scheduleClosures',
        <String, Object>{
          'tasks': <Map<String, Object>>[
            for (final ClosureArmedTask t in tasks)
              <String, Object>{
                'id': t.id,
                'date': t.date,
                'time': t.time,
              },
          ],
        },
      );
    } catch (_) {
      // جدولة التنبيهات اختيارية: الاسترداد عند التشغيل ينفّذ المتأخرة.
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod<void>('cancelAll');
    } catch (_) {
      // لا ضرر: التنبيهات تنفّذ مرة واحدة ثم تُزال عند تنفيذ المهمة.
    }
  }

  MethodChannel get _channel => MethodChannel(channelName);
}
