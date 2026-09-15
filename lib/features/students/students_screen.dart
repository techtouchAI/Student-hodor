/// إدارة الطلاب: إدراج/تعديل/صورة + توليد باج تلقائي برمز checksum.
library;

import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/badge_code.dart';
import '../../data/db.dart';
import '../../state/providers.dart';

/// تطبيع الاسم: إزالة تشكيل/تطويل/مسافات زائدة لكشف التكرار.
String normalizeName(String s) => s
    .replaceAll(RegExp(r'[\u064B-\u0652\u0640]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

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
            return const Center(child: Text('لا طلاب بعد'));
          }
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (BuildContext context, int i) {
              final Student s = list[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundImage: s.photoPath != null && File(s.photoPath!).existsSync()
                      ? FileImage(File(s.photoPath!))
                      : null,
                  child: s.photoPath == null ? const Icon(Icons.person) : null,
                ),
                title: Text(s.fullName),
                subtitle: Text('تسلسل: ${s.seq}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(Icons.badge),
                      onPressed: () => _showCode(s),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () => _edit(s),
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

  Future<void> _showCode(Student s) async {
    final AppDb db = ref.read(dbProvider);
    final Badge? badge = await (db.select(db.badges)
          ..where((b) => b.studentId.equals(s.id) & b.status.equals(0)))
        .getSingleOrNull();
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('رمز الباج الفعال'),
        content: Text(badge?.code ?? 'لا يوجد باج'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
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
    if (!mounted) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSt) => AlertDialog(
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
                  if (photoPath != null)
                    Image.file(
                      File(photoPath!),
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
        ),
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
    if (s == null) {
      final int seq = same.fold<int>(0, (int m, Student t) => t.seq > m ? t.seq : m) + 1;
      final String school = await db.setting('school_name') ?? '';
      final int yearShort = int.tryParse(year.start.substring(2, 4)) ?? 0;
      final int id = await db.into(db.students).insert(
            StudentsCompanion(
              yearId: Value(year.id),
              classId: Value(widget.classId),
              fullName: Value(trimmed),
              personKey: Value(normalizeName(trimmed)),
              seq: Value(seq),
              photoPath: Value(photoPath),
              createdAt: Value(DateTime.now().toIso8601String()),
            ),
          );
      await db.into(db.badges).insert(
            BadgesCompanion(
              studentId: Value(id),
              code: Value(
                BadgeCode.make(
                  schoolName: school,
                  sequence: seq,
                  yearShort: yearShort,
                ),
              ),
              issuedAt: Value(DateTime.now().toIso8601String()),
            ),
          );
      await db.logAudit('student_add', trimmed);
    } else {
      await (db.update(db.students)..where((t) => t.id.equals(s.id))).write(
        StudentsCompanion(
          fullName: Value(trimmed),
          photoPath: Value(photoPath),
        ),
      );
      await db.logAudit('student_edit', trimmed);
    }
  }
}
