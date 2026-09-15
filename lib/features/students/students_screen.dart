/// إدارة الطلاب: إدراج/تعديل/حذف + صورة دائمة + باج تلقائي برمز فريد.
library;

import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/name_utils.dart';
import '../../data/db.dart';
import '../../data/photo_store.dart';
import '../../state/providers.dart';

class StudentsScreen extends ConsumerStatefulWidget {
  const StudentsScreen({super.key, required this.classId, required this.title});

  final int classId;
  final String title;

  @override
  ConsumerState<StudentsScreen> createState() => _StudentsState();
}

class _StudentsState extends ConsumerState<StudentsScreen> {
  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: Text('طلاب ${widget.title}')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.person_add),
        label: const Text('طالب جديد'),
      ),
      body: StreamBuilder<List<Student>>(
        stream: (db.select(db.students)
              ..where((s) => s.classId.equals(widget.classId))
              ..orderBy(<OrderClauseGenerator<Students>>[
                (Students s) => OrderingTerm.asc(s.fullName),
              ]))
            .watch(),
        builder: (BuildContext context, AsyncSnapshot<List<Student>> snap) {
          final List<Student> list = snap.data ?? <Student>[];
          if (list.isEmpty) {
            return const Center(child: Text('لا طلاب بعد — أضف أول طالب'));
          }
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (BuildContext context, int i) {
              final Student s = list[i];
              final String? photo = s.photoPath;
              final bool hasPhoto =
                  photo != null && File(photo).existsSync();
              return ListTile(
                leading: CircleAvatar(
                  backgroundImage:
                      hasPhoto ? FileImage(File(photo!)) : null,
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
                      onPressed: () => context.push('/student/${s.id}'),
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
            },
          );
        },
      ),
    );
  }

  Future<void> _showBadge(Student s) async {
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
  }

  Future<void> _reissue(Student s) async {
    final AppDb db = ref.read(dbProvider);
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
    final Badge? row = await db.reissueBadge(s.id);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('الرمز الجديد: ${row?.code ?? '-'}')),
    );
  }

  Future<void> _delete(Student s) async {
    final AppDb db = ref.read(dbProvider);
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
    await db.deleteStudent(s.id);
    await PhotoStore.deleteIfExists(photo);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('حُذف ${s.fullName}')));
    }
  }

  Future<void> _edit(Student? s) async {
    final AppDb db = ref.read(dbProvider);
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
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
                    ),
                  IconButton(
                    icon: const Icon(Icons.camera_alt),
                    onPressed: () async {
                      final XFile? f = await ImagePicker()
                          .pickImage(source: ImageSource.camera);
                      if (f != null) {
                        setSt(() => photoPath = f.path);
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.photo_library),
                    onPressed: () async {
                      final XFile? f = await ImagePicker()
                          .pickImage(source: ImageSource.gallery);
                      if (f != null) {
                        setSt(() => photoPath = f.path);
                      }
                    },
                  ),
                  if (cur != null)
                    IconButton(
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
    if (ok != true || trimmed.length < 3) {
      return;
    }
    // كشف التكرار داخل نفس الصف على الاسم المطبّع.
    final List<Student> same = await (db.select(db.students)
          ..where((t) => t.classId.equals(widget.classId)))
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
    try {
      if (s == null) {
        final String? stored = await PhotoStore.copy(photoPath);
        await db.addStudent(
          yearId: year.id,
          classId: widget.classId,
          fullName: trimmed,
          photoPath: stored,
        );
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
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر الحفظ: $e')),
        );
      }
    }
  }
}
