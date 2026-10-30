/// محرر جدول الحصص: عدد الحصص وأسماؤها وأوقاتها.
///
/// هذا الجدول هو مصدر «أي حصة الآن؟» وحدّ التأخير لكل حصة. قواعده:
/// - ترتيب الصفوف هو ترتيب الحصص (1..N).
/// - كل حصة تنتهي بعد بدايتها، ولا تتداخل حصتان (التحقق في [LessonSchedule]).
/// - حذف حصة لها سجلات مرفوض من قاعدة البيانات ([LessonInUseException])
///   ويُعرض سببه هنا بلغة مفهومة — لا حذف صامت لتاريخ الطلاب.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_guard.dart';
import '../../core/late_time.dart';
import '../../core/lesson.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../state/providers.dart';

class LessonsScreen extends ConsumerStatefulWidget {
  const LessonsScreen({super.key});

  @override
  ConsumerState<LessonsScreen> createState() => _LessonsScreenState();
}

/// مسودة حصة في المحرر: معرّف 0 = جديدة، وإلا تُحدَّث هويتها لا تُستبدل.
class _Draft {
  _Draft({
    this.id = 0,
    required String name,
    required String start,
    required String end,
  })  : nameCtrl = TextEditingController(text: name),
        startCtrl = TextEditingController(text: start),
        endCtrl = TextEditingController(text: end);

  final int id;
  final TextEditingController nameCtrl;
  final TextEditingController startCtrl;
  final TextEditingController endCtrl;

  void dispose() {
    nameCtrl.dispose();
    startCtrl.dispose();
    endCtrl.dispose();
  }
}

class _LessonsScreenState extends ConsumerState<LessonsScreen> {
  final List<_Draft> _drafts = <_Draft>[];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final _Draft d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final AppDb db = ref.read(dbProvider);
      final List<LessonWindow> lessons = await db.lessonWindows();
      if (!mounted) {
        return;
      }
      final List<_Draft> old = <_Draft>[..._drafts];
      setState(() {
        _drafts
          ..clear()
          ..addAll(<_Draft>[
            for (final LessonWindow l in lessons)
              _Draft(
                id: l.id,
                name: l.displayName,
                start: l.start,
                end: l.end,
              ),
          ]);
        _loading = false;
        _error = null;
      });
      // التحكمات القديمة تُحرَّر بعد إعادة البناء: تحريرها قبل أن تُفكّ
      // عناصر `TextField` التي تستمع إليها يرفع «used after being disposed».
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final _Draft d in old) {
          d.dispose();
        }
      });
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'lessons:load');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  /// نهاية آخر حصة + 5 دقائق فاصل، ومدة 45 دقيقة افتراضية.
  void _add() {
    final _Draft? last = _drafts.isEmpty ? null : _drafts.last;
    String start = '08:00';
    if (last != null) {
      final int? endMinutes = parseArrivalMinutes(last.endCtrl.text.trim());
      if (endMinutes != null) {
        final int s = (endMinutes + 5).clamp(0, 23 * 60 + 59);
        start = _hhmm(s);
      }
    }
    final int startMinutes = parseArrivalMinutes(start) ?? 8 * 60;
    final int endMinutes =
        (startMinutes + 45).clamp(0, 23 * 60 + 59);
    setState(() {
      _drafts.add(
        _Draft(
          name: LessonLabels.of(_drafts.length + 1),
          start: start,
          end: _hhmm(endMinutes),
        ),
      );
    });
  }

  static String _hhmm(int minutes) {
    final int h = (minutes ~/ 60) % 24;
    final int m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  Future<void> _pickTime(
    TextEditingController ctrl, {
    required void Function() onChanged,
  }) async {
    final int? current = parseArrivalMinutes(ctrl.text.trim());
    final TimeOfDay initial = current == null
        ? const TimeOfDay(hour: 8, minute: 0)
        : TimeOfDay(hour: current ~/ 60, minute: current % 60);
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: 'اختر الوقت',
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    ctrl.text = _hhmm(picked.hour * 60 + picked.minute);
    onChanged();
  }

  Future<void> _save() async {
    final List<LessonWindow> windows = <LessonWindow>[
      for (int i = 0; i < _drafts.length; i++)
        LessonWindow(
          id: _drafts[i].id,
          slot: i + 1,
          name: _drafts[i].nameCtrl.text,
          start: _drafts[i].startCtrl.text.trim(),
          end: _drafts[i].endCtrl.text.trim(),
        ),
    ];
    setState(() => _saving = true);
    try {
      await ref.read(dbProvider).saveLessons(windows);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حُفظ جدول الحصص')),
      );
      await _load();
    } on FormatException catch (e) {
      _snack(e.message);
    } on LessonInUseException catch (e) {
      _snack(e.toString());
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'lessons:save');
      _snack('تعذر الحفظ: $e');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// إعادة الملء بالجدول الافتراضي في المحرر **دون حفظ** — يمكن للمستخدم
  /// تعديله أو التراجع قبل الحفظ.
  void _resetDrafts() {
    final List<_Draft> old = <_Draft>[..._drafts];
    setState(() {
      _drafts
        ..clear()
        ..addAll(<_Draft>[
          for (final LessonTemplate t in LessonSchedule.defaults)
            _Draft(name: t.name, start: t.start, end: t.end),
        ]);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final _Draft d in old) {
        d.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('جدول الحصص'),
        actions: <Widget>[
          IconButton(
            tooltip: 'الجدول الافتراضي',
            icon: const Icon(Icons.restart_alt),
            onPressed: _drafts.isEmpty ? null : _resetDrafts,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('حصة'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error == null
              ? _body()
              : LoadErrorCard(message: _error!, onRetry: () => _load())),
    );
  }

  Widget _body() {
    return Column(
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'هذا الجدول يحكم تسجيل الحضور: تُفتح جلسة لكل حصة، ويُحسب '
            'التأخير من بداية الحصة + دقائق السماح في الإعدادات. '
            'تعديل الوقت لا يمسّ السجلات السابقة.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            itemCount: _drafts.length,
            itemBuilder: (BuildContext context, int i) => _card(i),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving || _drafts.isEmpty ? null : _save,
                    icon: const Icon(Icons.save),
                    label: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ الجدول'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(int i) {
    final _Draft d = _drafts[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 14,
                  child: Text('${i + 1}', style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: d.nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'اسم الحصة',
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'حذف الحصة',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _drafts.length == 1
                      ? null
                      : () => setState(() {
                            _drafts.removeAt(i).dispose();
                          }),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: _timeField(d.startCtrl, 'البداية', () {
                    setState(() {});
                  }),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _timeField(d.endCtrl, 'النهاية', () {
                    setState(() {});
                  }),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _timeField(
    TextEditingController ctrl,
    String label,
    VoidCallback onChanged,
  ) =>
      TextField(
        controller: ctrl,
        keyboardType: TextInputType.datetime,
        decoration: InputDecoration(
          labelText: label,
          hintText: 'HH:mm',
          isDense: true,
          suffixIcon: IconButton(
            tooltip: 'اختيار الوقت',
            icon: const Icon(Icons.schedule),
            onPressed: () => _pickTime(ctrl, onChanged: onChanged),
          ),
        ),
      );
}
