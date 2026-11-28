/// حوار تحرير إجازة — واحد للإضافة والتعديل: يعيد [LeaveDraft] عند «حفظ»
/// و`null` عند الإلغاء. لا يكتب في قاعدة البيانات؛ الحفظ مسؤولية
/// `LeavesService` (معاملة واحدة + مزامنة الحضور + تنبيهات حد الفصل).
library;

import 'package:flutter/material.dart';

import '../../core/lesson.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/leaves_service.dart';

/// يفتح الحوار: [initial] = `null` ⇒ «إجازة جديدة»، وإلا ⇒ «تعديل إجازة»
/// بقيمها الحالية.
Future<LeaveDraft?> showLeaveEditor(
  BuildContext context, {
  required List<Student> students,
  required List<LessonWindow> lessons,
  LeaveDraft? initial,
}) =>
    showDialog<LeaveDraft>(
      context: context,
      builder: (BuildContext context) => LeaveEditorDialog(
        students: students,
        lessons: lessons,
        initial: initial,
      ),
    );

class LeaveEditorDialog extends StatefulWidget {
  const LeaveEditorDialog({
    super.key,
    required this.students,
    required this.lessons,
    this.initial,
  });

  final List<Student> students;
  final List<LessonWindow> lessons;
  final LeaveDraft? initial;

  bool get isEdit => initial != null;

  @override
  State<LeaveEditorDialog> createState() => _LeaveEditorDialogState();
}

class _LeaveEditorDialogState extends State<LeaveEditorDialog> {
  static final DateTime _firstDate = DateTime(2015);
  static final DateTime _lastDate = DateTime(2040, 12, 31);

  // بحث في الطلاب داخل الحوار: مع كثرة الطلاب يصعب الوصول للمطلوب.
  final TextEditingController _search = TextEditingController();
  late final TextEditingController _reason;

  Student? _picked;
  late DateTime _start;
  late DateTime _end;
  late int _type;
  // نطاق الحصص: فارغ = كل حصص اليوم.
  int? _fromSlot;
  int? _toSlot;

  @override
  void initState() {
    super.initState();
    final LeaveDraft? init = widget.initial;
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    _reason = TextEditingController(text: init?.reason ?? '');
    _start = _parseDate(init?.start) ?? today;
    _end = _parseDate(init?.end) ?? _start;
    if (_end.isBefore(_start)) {
      _end = _start;
    }
    _type = init == null || init.type < 0 || init.type >= leaveTypeNames.length
        ? 0
        : init.type;
    _fromSlot = init?.fromSlot;
    _toSlot = init?.toSlot;
    _picked = init == null
        ? (widget.students.isEmpty ? null : widget.students.first)
        : _studentById(init.studentId);
  }

  @override
  void dispose() {
    _search.dispose();
    _reason.dispose();
    super.dispose();
  }

  static DateTime? _parseDate(String? key) =>
      key == null ? null : DateTime.tryParse(key);

  Student? _studentById(int id) {
    for (final Student s in widget.students) {
      if (s.id == id) {
        return s;
      }
    }
    return null;
  }

  List<Student> _matching(String raw) {
    final String q = raw.trim().toLowerCase();
    if (q.isEmpty) {
      return widget.students;
    }
    return <Student>[
      for (final Student s in widget.students)
        if (s.fullName.toLowerCase().contains(q)) s,
    ];
  }

  /// خيارات الحصص: حصص الجدول الحالية، مع أي رقم محفوظ في الإجازة لم يعد
  /// في الجدول (حتى لا تنهار القائمة المنسدلة بقيمة بلا عنصر).
  List<(int, String)> get _slotOptions {
    final Map<int, String> bySlot = <int, String>{
      for (final LessonWindow l in widget.lessons) l.slot: l.displayName,
    };
    for (final int? s in <int?>[_fromSlot, _toSlot]) {
      if (s != null) {
        bySlot.putIfAbsent(s, () => LessonLabels.of(s));
      }
    }
    final List<int> slots = bySlot.keys.toList()..sort();
    return <(int, String)>[for (final int s in slots) (s, bySlot[s]!)];
  }

  /// حدود المنتقي تتّسع لتشمل القيمة المحفوظة دائمًا (إجازة قديمة خارج
  /// المدى الافتراضي لا تُسقط منتقي التاريخ بتأكيد `initialDate`).
  static DateTime _minDate(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
  static DateTime _maxDate(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

  Future<void> _pickStart() async {
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: _minDate(_firstDate, _start),
      lastDate: _maxDate(_lastDate, _end),
    );
    if (d != null && mounted) {
      setState(() {
        _start = d;
        if (_end.isBefore(_start)) {
          _end = _start;
        }
      });
    }
  }

  Future<void> _pickEnd() async {
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: _end,
      firstDate: _start,
      lastDate: _maxDate(_lastDate, _end),
    );
    if (d != null && mounted) {
      setState(() => _end = d);
    }
  }

  void _save() {
    final Student? stu = _picked;
    if (stu == null || _start.isAfter(_end)) {
      return;
    }
    Navigator.pop(
      context,
      LeaveDraft(
        studentId: stu.id,
        start: SchoolTime.dateKey(_start),
        end: SchoolTime.dateKey(_end),
        type: _type,
        fromSlot: _fromSlot,
        toSlot: _fromSlot == null ? null : _toSlot,
        reason: _reason.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Student> filtered = _matching(_search.text);
    final List<(int, String)> slots = _slotOptions;
    return AlertDialog(
      title: Text(widget.isEdit ? 'تعديل إجازة' : 'إجازة جديدة'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _search,
              // عند تصفية الطلاب: يُحدَّد أول طالب مطابق تلقائيًا
              // (ولا يبقى اختيار قديم خارج القائمة المعروضة).
              onChanged: (String v) {
                final List<Student> matches = _matching(v);
                setState(() {
                  if (matches.isEmpty) {
                    _picked = null;
                  } else if (!matches.contains(_picked)) {
                    _picked = matches.first;
                  }
                });
              },
              decoration: const InputDecoration(
                labelText: 'بحث في الطلاب',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
            if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('لا طالب مطابق للبحث', textAlign: TextAlign.center),
              ),
            DropdownButtonFormField<Student>(
              key: ValueKey<Student?>(_picked),
              initialValue: filtered.contains(_picked) ? _picked : null,
              isExpanded: true,
              items: <DropdownMenuItem<Student>>[
                for (final Student s in filtered)
                  DropdownMenuItem<Student>(value: s, child: Text(s.fullName)),
              ],
              onChanged: (Student? s) => setState(() => _picked = s),
              decoration: const InputDecoration(labelText: 'الطالب'),
            ),
            ListTile(
              title: const Text('من'),
              subtitle: Text(SchoolTime.dateKey(_start)),
              onTap: _pickStart,
            ),
            ListTile(
              title: const Text('إلى'),
              subtitle: Text(SchoolTime.dateKey(_end)),
              onTap: _pickEnd,
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    key: ValueKey<String>('from-$_fromSlot'),
                    initialValue: _fromSlot,
                    isExpanded: true,
                    items: <DropdownMenuItem<int?>>[
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('كل الحصص'),
                      ),
                      for (final (int slot, String name) in slots)
                        DropdownMenuItem<int?>(value: slot, child: Text(name)),
                    ],
                    onChanged: (int? v) => setState(() {
                      _fromSlot = v;
                      if (v == null) {
                        _toSlot = null;
                      } else if (_toSlot != null && _toSlot! < v) {
                        _toSlot = v;
                      }
                    }),
                    decoration: const InputDecoration(labelText: 'من الحصة'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    key: ValueKey<String>('to-$_toSlot'),
                    initialValue: _toSlot,
                    isExpanded: true,
                    items: <DropdownMenuItem<int?>>[
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('آخر اليوم'),
                      ),
                      for (final (int slot, String name) in slots)
                        DropdownMenuItem<int?>(value: slot, child: Text(name)),
                    ],
                    onChanged: _fromSlot == null
                        ? null
                        : (int? v) => setState(() {
                              _toSlot = v;
                              if (v != null &&
                                  _fromSlot != null &&
                                  v < _fromSlot!) {
                                _fromSlot = v;
                              }
                            }),
                    decoration: const InputDecoration(labelText: 'إلى الحصة'),
                  ),
                ),
              ],
            ),
            DropdownButtonFormField<int>(
              key: ValueKey<int>(_type),
              initialValue: _type,
              items: <DropdownMenuItem<int>>[
                for (int i = 0; i < leaveTypeNames.length; i++)
                  DropdownMenuItem<int>(
                    value: i,
                    child: Text(leaveTypeNames[i]),
                  ),
              ],
              onChanged: (int? t) => setState(() => _type = t ?? 0),
              decoration: const InputDecoration(labelText: 'النوع'),
            ),
            TextField(
              controller: _reason,
              decoration: const InputDecoration(labelText: 'السبب (اختياري)'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _picked == null ? null : _save,
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
