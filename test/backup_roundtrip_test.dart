/// النسخة الاحتياطية: حاوية zip (بيان + صور + تدقيق) ذهاباً وإياباً،
/// وملف JSON القديم يُسترجع كما هو.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:student_hodor/data/backup_service.dart';
import 'package:student_hodor/data/db.dart';

Future<(AppDb, Student)> _seed({String? phone, String? photoPath}) async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final int year = await db.into(db.academicYears).insert(
        const AcademicYearsCompanion(
          name: Value('2026-2027'),
          start: Value('2026-09-01'),
          end: Value('2027-06-30'),
          active: Value(true),
        ),
      );
  final int cls = await db.into(db.schoolClasses).insert(
        SchoolClassesCompanion(
          yearId: Value(year),
          grade: const Value('السادس'),
          section: const Value('أ'),
        ),
      );
  final int id = await db.addStudent(
    yearId: year,
    classId: cls,
    fullName: 'طالب النسخة',
    phone: phone,
    photoPath: photoPath,
  );
  final Student s = await (db.select(db.students)
        ..where((t) => t.id.equals(id)))
      .getSingle();
  return (db, s);
}

/// بيان بصيغة 1 (بلا تدقيق ولا صور) للتوافق الرجعي.
Future<Map<String, Object?>> _legacySnapshotOf(AppDb db) async =>
    <String, Object?>{
      'format': 'student-hodor-backup',
      'version': 1,
      'at': DateTime.now().toIso8601String(),
      'settings': await db.allSettings(),
      'years': <Map<String, Object?>>[
        for (final AcademicYear y in await db.select(db.academicYears).get())
          y.toJson(),
      ],
      'classes': <Map<String, Object?>>[
        for (final SchoolClass c in await db.select(db.schoolClasses).get())
          c.toJson(),
      ],
      'students': <Map<String, Object?>>[
        for (final Student s in await db.select(db.students).get()) s.toJson(),
      ],
    };

void main() {
  test('تسلسل الطالب يحمل الهاتف ذهاباً وإياباً', () async {
    final (AppDb db, Student s) = await _seed(phone: '07712345678');
    addTearDown(db.close);
    final Map<String, Object?> back =
        jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>;
    expect(Student.fromJson(back).phone, '07712345678');
  });

  test('حاوية zip: الصور والتدقيق والهاتف ذهاباً وإياباً', () async {
    final Directory srcDir =
        await Directory.systemTemp.createTemp('hodor-photo-src');
    addTearDown(() => srcDir.delete(recursive: true));
    final List<int> raw = List<int>.generate(256, (int i) => i % 251);
    final File src = File(p.join(srcDir.path, 'face.jpg'));
    await src.writeAsBytes(raw);
    final (AppDb db1, Student s) =
        await _seed(phone: '07712345678', photoPath: src.path);
    addTearDown(db1.close);
    await db1.logAudit('test_action', 'test_details');

    final Uint8List zip = await BackupService(db1).exportBytes();
    final Archive archive = ZipDecoder().decodeBytes(zip);
    final List<String> names =
        <String>[for (final ArchiveFile f in archive) f.name];
    expect(names, contains(BackupService.manifestName));
    expect(names, contains('photos/${s.id}.jpg'));

    final Directory dstDir =
        await Directory.systemTemp.createTemp('hodor-photo-dst');
    addTearDown(() => dstDir.delete(recursive: true));
    final AppDb db2 = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    await BackupService(
      db2,
      photoInstaller: (String fileName, List<int> bytes) async {
        final File f = File(p.join(dstDir.path, fileName));
        await f.writeAsBytes(bytes);
        return f.path;
      },
    ).restoreFull(zip);

    final Student r = await db2.select(db2.students).getSingle();
    expect(r.fullName, 'طالب النسخة');
    expect(r.phone, '07712345678');
    expect(r.photoPath, startsWith(dstDir.path));
    expect(await File(r.photoPath!).readAsBytes(), raw);
    final List<AuditLog> logs = await db2.select(db2.auditLogs).get();
    expect(logs.any((AuditLog l) => l.action == 'test_action'), isTrue);
    expect(
      logs.any((AuditLog l) => l.action == 'backup_restore_full'),
      isTrue,
    );
  });

  test('نسخة JSON قديمة تُسترجع كاملة (بلا صور ولا تدقيق مستورد)', () async {
    final (AppDb db1, _) = await _seed(phone: '07712345678');
    addTearDown(db1.close);
    final Map<String, Object?> snap = await _legacySnapshotOf(db1);
    final List<Map<String, Object?>> students =
        snap['students']! as List<Map<String, Object?>>;
    students.first.remove('phone');
    final AppDb db2 = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    await BackupService(db2).restoreFull(utf8.encode(jsonEncode(snap)));
    final Student s = await db2.select(db2.students).getSingle();
    expect(s.phone, isNull);
    expect(s.photoPath, isNull);
  });
}
