/// منتقي الحصة: شريط أفقي موحّد لكل الشاشات (المسح، كشف اليوم، التقارير).
///
/// سبب وجوده كمكوّن واحد: «أي حصة أعرض؟» سؤال واحد في أربع شاشات؛ تكراره
/// يعني اختلاف شكل/سلوك بينها. الشريط أفقي ليحفظ ارتفاع الشاشة، ويُظهر رقم
/// الحصة واسمها ووقتها في التلميح.
library;

import 'package:flutter/material.dart';

import '../../core/lesson.dart';

class LessonPicker extends StatelessWidget {
  const LessonPicker({
    super.key,
    required this.lessons,
    required this.selectedId,
    required this.onSelect,
    this.showTimes = false,
  });

  final List<LessonWindow> lessons;
  final int? selectedId;
  final ValueChanged<LessonWindow> onSelect;

  /// إظهار وقت كل حصة داخل الشريحة (مفيد عندما تكون الأسماء متشابهة).
  final bool showTimes;

  @override
  Widget build(BuildContext context) {
    if (lessons.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: lessons.length,
        separatorBuilder: (BuildContext context, int i) =>
            const SizedBox(width: 6),
        itemBuilder: (BuildContext context, int i) {
          final LessonWindow l = lessons[i];
          return Center(
            child: ChoiceChip(
              selected: l.id == selectedId,
              tooltip: l.timeLabel,
              avatar: CircleAvatar(
                radius: 10,
                child: Text(
                  '${l.slot}',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
              label: Text(
                showTimes ? '${l.displayName} · ${l.start}' : l.displayName,
              ),
              onSelected: (_) => onSelect(l),
            ),
          );
        },
      ),
    );
  }
}
