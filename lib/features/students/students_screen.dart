/// إدارة الطلاب: إدراج/تعديل/حذف + صورة دائمة + باج تلقائي برمز فريد.
///
/// الشاشة لا تعتمد على معاملة الرابط: تُحلّ صفّها من قاعدة البيانات
/// ([AppDb.resolveClassRef]) فإن جاء المعرّف ناقصاً/محذوفاً تعرض منتقي صفوف أو
/// رسالة واضحة — لا صفحة بيضاء ولا قائمة فارغة كاذبة.
library;

import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/error_guard.dart';
import '../../core/name_utils.dart';
import '../../core/nav.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../data/photo_store.dart';
import '../../state/providers.dart';

class StudentsScreen extends ConsumerStatefulWidget {
  const StudentsScreen({super.key, required this.classRef});

  final ClassRef classRef;

  @override
  ConsumerState<StudentsScreen> createState() => _StudentsState();
}

class _StudentsState extends ConsumerState<StudentsScreen> {
  ClassRef? _class;
  Stream<List<Student>>? _students;
  bool _resolving = true;
  String? _resolveError;
  List<SchoolClass> _options = <SchoolClass>[];

  @override
  void initState() {
    super.initState();
    _start(widget.classRef);
  }

  @override
  void didUpdateWidget(StudentsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.classRef.id != widget.classRef.id ||
        oldWidget.classRef.title != widget.classRef.title) {
      _start(widget.classRef);
    }
  }

  Future<void> _start(ClassRef requested) async {
    setState(() {
      _resolving = true;
      _resolveError = null;
    });
    try {
      final AppDb db = ref.read(dbProvider);
      final (int count, ClassRef? ref0) = await db.resolveClassRef(requested);
      if (!mounted) {
        return;
      }
      if (ref0 == null) {
        _options = await _classesOfActiveYear(db);
        if (!mounted) {
          return;
        }
        setState(() {
          _class = null;
          _students = null;
          _resolving = false;
          _resolveError = count == 0
              ? 'لا توجد صفوف في السنة الفعّالة — أضف صفاً من شاشة الصفوف.'
              : null;
        });
        return;
      }
      setState(() {
        _class = ref0;
        _students = (db.select(db.students)
              ..where((s) => s.classId.equals(ref0.id))
              ..orderBy(<OrderClauseGenerator<Students>>[
                (Students s) => OrderingTerm.asc(s.fullName),
              ]))
            .watch();
        _resolving = false;
      });
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'students:resolve');
      if (mounted) {
        setState(() {
          _resolving = false;
          _resolveError = '$e';
        });
      }
    }
  }

  Future<List<SchoolClass>> _classesOfActiveYear(AppDb db) async {
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return <SchoolClass>[];
    }
    return (db.select(db.schoolClasses)
          ..where((c) => c.yearId.equals(year.id))
          ..orderBy(<OrderClauseGenerator<SchoolClasses>>[
            (SchoolClasses c) => OrderingTerm.asc(c.grade),
            (SchoolClasses c) => OrderingTerm.asc(c.section),
          ]))
        .get();
  }

  Future<void> _pickClass() async {
    if (_options.isEmpty) {
      return;
    }
    final SchoolClass? c = await showDialog<SchoolClass>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('اختر صفاً'),
        children: <Widget>[
          for (final SchoolClass o in _options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Text('${o.grade} ـ ${o.section}'),
            ),
        ],
      ),
    );
    if (c != null) {
      await _start(ClassRef(id: c.id, title: '${c.grade} ـ ${c.section}'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ClassRef? c = _class;
    return Scaffold(
      appBar: AppBar(
        title: Text(c == null ? 'الطلاب' : 'طلاب ${c.displayTitle}'),
      ),
      floatingActionButton: c == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(null),
              icon: const Icon(Icons.person_add),
              label: const Text('طالب جديد'),
            ),
      body: _body(c),
    );
  }

  Widget _body(ClassRef? c) {
    if (_resolving) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? err = _resolveError;
    if (err != null) {
      return Center(
        child: LoadErrorCard(message: err, onRetry: () => _start(widget.classRef)),
      );
    }
    if (c == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.touch_app, size: 48),
              const SizedBox(height: 8),
              const Text(
                'لم يُحدَّد صف لهذه الشاشة.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              if (_options.isNotEmpty)
                FilledButton.icon(
                  onPressed: _pickClass,
                  icon: const Icon(Icons.class_),
                  label: const Text('اختر صفاً'),
                )
              else
                FilledButton.icon(
                  onPressed: () => context.pushNamed(AppRoutes.classes),
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة صف'),
                ),
            ],
          ),
        ),
      );
    }
    final Stream<List<Student>>? stream = _students;
    if (stream == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return StreamGuard<List<Student>>(
      stream: stream,
      builder: (BuildContext context, List<Student> list) {
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.person_outline, size: 48),
                  const SizedBox(height: 8),
                  Text('لا طلاب بعد في ${c.displayTitle}'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => _edit(null),
                    icon: const Icon(Icons.person_add),
                    label: const Text('أضف أول طالب'),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView.builder(
          itemCount: list.length,
          itemBuilder: (BuildContext context, int i) =>
              _studentTile(list[i]),
        );
      },
    );
  }

  Widget _studentTile(Student s) {
    final String? photoPath = s.photoPath;
    final bool hasPhoto =
        photoPath != null && photoPath.isNotEmpty && File(photoPath).existsSync();
    return ListTile(
      leading: CircleAvatar(
        backgroundImage: hasPhoto ? FileImage(File(photoPath)) : null,
        child: hasPhoto ? null : const Icon(Icons.person),
      ),
      title: Text(s.fullName),
      subtitle: Text('رقم الطالب: ${s.seq}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: 'الباج والرمز',
            icon: const Icon(Icons.badge),
            onPressed: () => _showBadge(s),
          ),
          IconButton(
            tooltip: 'ملف الحضور',
            icon: const Icon(Icons.assessment),
            onPressed: () => context.pushNamed(
              AppRoutes.student,
              pathParameters: <String, String>{'id': '${s.id}'},
            ),
          ),
          IconButton(
            tooltip: 'تعديل',
            icon: const Icon(Icons.edit),
            onPressed: () => _edit(s),
          ),
          IconButton(
            tooltip: 'حذف',
            icon: const Icon(Icons.delete),
            onPressed: () => _delete(s),
          ),
        ],
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showBadge(Student s) async {
    try {
      final AppDb db = ref.read(dbProvider);
      final Badge? badge = await db.activeBadgeOf(s.id);
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('الباج الفعال'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('الرمز: ${badge?.code ?? 'لا يوجد باج'}'),
              if (badge != null && badge.version > 1)
                Text('نسخة بدل فاقد: ${badge.version}'),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إغلاق'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await _reissue(s);
              },
              child: const Text('بدل فاقد (رمز جديد)'),
            ),
          ],
        ),
      );
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'students:badge');
      _snack('تعذر قراءة الباج: $e');
    }
  }

  Future<void> _reissue(Student s) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('إصدار باج بدل فاقد'),
        content: Text(
          'سيُبطل الباج الحالي لـ«${s.fullName}» ويُصدر باج برمز جديد؛ '
          'الباج القديم لن يُقرأ بعد الآن.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إصدار'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    try {
      final Badge? row = await ref.read(dbProvider).reissueBadge(s.id);
      _snack('الرمز الجديد: ${row?.code ?? '-'}');
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'students:reissue');
      _snack('تعذر إصدار بدل فاقد: $e');
    }
  }

  Future<void> _delete(Student s) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('حذف طالب'),
        content: Text(
          'سيُحذف «${s.fullName}» مع باجاته وسجلات حضوره وإجازاته. '
          'لا يمكن التراجع. متابعة؟',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    final String? photo = s.photoPath;
    try {
      await ref.read(dbProvider).deleteStudent(s.id);
      await PhotoStore.deleteIfExists(photo);
      _snack('حُذف ${s.fullName}');
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'students:delete');
      _snack('تعذر الحذف: $e');
    }
  }

  Future<void> _edit(Student? s) async {
    final AppDb db = ref.read(dbProvider);
    final int classId = _class?.id ?? widget.classRef.id;
    if (classId <= 0) {
      _snack('اختر صفاً أولاً');
      return;
    }
    AcademicYear? year;
    try {
      year = await db.activeYear();
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'students:year');
      _snack('تعذر قراءة السنة الفعّالة: $e');
      return;
    }
    if (year == null) {
      _snack('لا توجد سنة فعّالة — أنشئها من شاشة السنوات');
      return;
    }
    final TextEditingController name =
        TextEditingController(text: s?.fullName ?? '');
    String? photoPath = s?.photoPath;
    final String? originalPhoto = s?.photoPath;
    if (!mounted) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSt) {
          final String? cur = photoPath;
          return AlertDialog(
            title: Text(s == null ? 'إضافة طالب' : 'تعديل طالب'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'الاسم الكامل'),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    if (cur != null && File(cur).existsSync())
                      Image.file(
                        File(cur),
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image,
                          size: 48,
                        ),
                      ),
                    IconButton(
                      tooltip: 'التقاط صورة',
                      icon: const Icon(Icons.camera_alt),
                      onPressed: () async {
                        try {
                          final XFile? f = await ImagePicker()
                              .pickImage(source: ImageSource.camera);
                          if (f != null) {
                            setSt(() => photoPath = f.path);
                          }
                        } catch (e) {
                          _snack('تعذر فتح الكاميرا: $e');
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'من المعرض',
                      icon: const Icon(Icons.photo_library),
                      onPressed: () async {
                        try {
                          final XFile? f = await ImagePicker()
                              .pickImage(source: ImageSource.gallery);
                          if (f != null) {
                            setSt(() => photoPath = f.path);
                          }
                        } catch (e) {
                          _snack('تعذر فتح المعرض: $e');
                        }
                      },
                    ),
                    if (cur != null)
                      IconButton(
                        tooltip: 'إزالة الصورة',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => setSt(() => photoPath = null),
                      ),
                  ],
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('حفظ'),
              ),
            ],
          );
        },
      ),
    );
    final String trimmed = name.text.trim();
    if (ok != true) {
      return;
    }
    if (trimmed.length < 3) {
      _snack('الاسم قصير جداً — اكتب الاسم الكامل');
      return;
    }
    try {
      // كشف التكرار داخل نفس الصف على الاسم المطبّع.
      final List<Student> same = await (db.select(db.students)
            ..where((t) => t.classId.equals(classId)))
          .get();
      final bool dup = same.any(
        (Student t) =>
            normalizeName(t.fullName) == normalizeName(trimmed) && t.id != s?.id,
      );
      if (dup && mounted) {
        final bool? force = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('اسم مشابه موجود في الصف'),
            content: const Text('قد يكون الطالب مكرراً. إضافة على أي حال؟'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('تراجع'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('أضف'),
              ),
            ],
          ),
        );
        if (force != true) {
          return;
        }
      }
      if (s == null) {
        final String? stored = await PhotoStore.copy(photoPath);
        await db.addStudent(
          yearId: year.id,
          classId: classId,
          fullName: trimmed,
          photoPath: stored,
        );
        _snack('أُضيف $trimmed');
      } else {
        String? stored = s.photoPath;
        if (photoPath != originalPhoto) {
          if (photoPath == null) {
            await PhotoStore.deleteIfExists(originalPhoto);
            stored = null;
          } else {
            stored = await PhotoStore.copy(photoPath);
            if (stored != originalPhoto) {
              await PhotoStore.deleteIfExists(originalPhoto);
            }
          }
        }
        await (db.update(db.students)..where((t) => t.id.equals(s.id))).write(
          StudentsCompanion(
            fullName: Value(trimmed),
            photoPath: Value(stored),
          ),
        );
        await db.logAudit('student_edit', trimmed);
        _snack('حُفظت التعديلات');
      }
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'students:save');
      _snack('تعذر الحفظ: $e');
    }
  }
}
