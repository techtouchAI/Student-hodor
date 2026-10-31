/// دورة حياة ملفات الصور حول الاستعادة الكاملة.
///
/// التثبيت يسبق معاملة قاعدة البيانات، فالفشل بعد التثبيت كان يترك ملفات
/// يتيمة. هذه الاختبارات تثبت السياسة التي تغلق ذلك: يُحذف **فقط** ما
/// أنشأته المحاولة، ولا يُمسّ ملف سبق وجوده أو يشير إليه سجل قائم.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:student_hodor/data/backup_service.dart';
import 'package:student_hodor/data/db.dart';

Future<AppDb> _db() async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final int yearId = await db.into(db.academicYears).insert(
        const AcademicYearsCompanion(
          name: Value('2026-2027'),
          start: Value('2026-09-01'),
          end: Value('2027-06-30'),
          active: Value(true),
        ),
      );
  final int classId = await db.into(db.schoolClasses).insert(
        SchoolClassesCompanion(
          yearId: Value(yearId),
          grade: const Value('السادس'),
          section: const Value('أ'),
        ),
      );
  await db.addStudent(yearId: yearId, classId: classId, fullName: 'طالب قائم');
  return db;
}

/// بيان نسخة v2 (بلا جدول حصص) مع صورة للطالب رقم 1.
Map<String, Object?> _manifest() => <String, Object?>{
      'format': 'student-hodor-backup',
      'version': 2,
      'at': '2026-09-01T07:00:00.000',
      'settings': <String, Object?>{'school_name': 'مدرسة النسخة'},
      'years': <Map<String, Object?>>[
        <String, Object?>{
          'id': 1,
          'name': '2026-2027',
          'start': '2026-09-01',
          'end': '2027-06-30',
          'active': true,
          'closed': false,
          'closedAt': null,
        },
      ],
      'classes': <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'yearId': 1, 'grade': 'السادس', 'section': 'أ'},
      ],
      'students': <Map<String, Object?>>[
        <String, Object?>{
          'id': 1,
          'yearId': 1,
          'classId': 1,
          'fullName': 'طالب النسخة',
          'personKey': 'طالب النسخة',
          'seq': 1,
          'photoPath': '/old/device/photos/x.jpg',
          'phone': null,
          'createdAt': '2026-09-01T07:00:00.000',
        },
      ],
      'holidays': <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'date': '2026-09-20', 'title': 'عطلة'},
      ],
    };

Uint8List _zipOf(
  Map<String, Object?> manifest, {
  Map<String, List<int>> photos = const <String, List<int>>{},
}) {
  final Archive archive = Archive();
  final List<int> json = utf8.encode(jsonEncode(manifest));
  archive.addFile(ArchiveFile(BackupService.manifestName, json.length, json));
  photos.forEach((String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  late Directory dir;
  late int installedCalls;

  /// مثبِّت يكتب في مجلد الاختبار ويعيد المسار الجديد (كالافتراضي: ملف جديد).
  Future<String> installer(String fileName, List<int> bytes) async {
    installedCalls++;
    final File f = File(p.join(dir.path, 'new-$installedCalls-$fileName'));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hodor-photo-lifecycle-');
    installedCalls = 0;
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  test('فشل الفحص لا يثبّت أي صورة ولا ينشئ أي ملف', () async {
    final AppDb db = await _db();
    addTearDown(db.close);
    final Map<String, Object?> bad = _manifest();
    // مرجع صف غير موجود: يُرفض في `_planOf` قبل تثبيت الصور.
    bad['classes'] = <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'yearId': 999, 'grade': 'x', 'section': 'أ'},
    ];
    final Uint8List zip = _zipOf(bad, photos: <String, List<int>>{
      'photos/1.jpg': <int>[1, 2, 3],
    });
    final BackupService svc = BackupService(
      db,
      photoInstaller: installer,
      photoSnapshot: () async => <String>{},
    );

    await expectLater(
      svc.inspect(zip),
      throwsA(isA<BackupValidationException>()),
    );
    await expectLater(
      svc.restoreFull(zip),
      throwsA(isA<BackupValidationException>()),
    );
    expect(installedCalls, 0, reason: 'لا تثبيت قبل نجاح التحقق');
    expect(dir.listSync(), isEmpty, reason: 'لا ملفات دائمة ولا مؤقتة');
  });

  test('فشل الاستعادة بعد التثبيت يحذف ما أنشأته المحاولة وحدها', () async {
    final AppDb db = await _db();
    addTearDown(db.close);
    // ملف موجود قبل العملية في المجلد نفسه.
    final File old = File(p.join(dir.path, 'old.jpg'));
    await old.writeAsBytes(<int>[9, 9, 9]);

    final Map<String, Object?> manifest = _manifest();
    manifest['holidays'] = <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'date': '2026-09-20', 'title': 'أ'},
      <String, Object?>{'id': 2, 'date': '2026-09-20', 'title': 'مكرر'},
    ];
    final Uint8List zip = _zipOf(manifest, photos: <String, List<int>>{
      'photos/1.jpg': <int>[1, 2, 3],
    });
    final List<String> createdBefore = dir
        .listSync()
        .whereType<File>()
        .map((File f) => f.path)
        .toList();

    await expectLater(
      BackupService(
        db,
        photoInstaller: installer,
        photoSnapshot: () async => createdBefore.toSet(),
      ).restoreFull(zip),
      throwsA(
        isA<BackupApplyException>().having(
          (BackupApplyException e) => e.message,
          'message',
          contains('نُظّف 1 ملف صورة'),
        ),
      ),
    );

    expect(installedCalls, 1, reason: 'الصورة ثبتت فعلاً قبل فشل المعاملة');
    expect(old.existsSync(), isTrue, reason: 'ملف سابق لا يُمس');
    final List<String> left = dir
        .listSync()
        .whereType<File>()
        .map((File f) => p.basename(f.path))
        .toList();
    expect(left, <String>['old.jpg'], reason: 'لم يبقَ إلا الملف السابق');
  });

  test('ملف كان موجوداً قبل الاستعادة لا يُحذف ولو أعاده المثبِّت', () async {
    final AppDb db = await _db();
    addTearDown(db.close);
    final File shared = File(p.join(dir.path, 'shared.jpg'));
    await shared.writeAsBytes(<int>[7]);

    final Uint8List zip = _zipOf(
      _manifest()..['holidays'] = <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'date': '2026-09-20', 'title': 'أ'},
        <String, Object?>{'id': 2, 'date': '2026-09-20', 'title': 'مكرر'},
      ],
      photos: <String, List<int>>{
        'photos/1.jpg': <int>[1, 2, 3],
      },
    );

    await expectLater(
      BackupService(
        db,
        // مثبِّت «سيئ» يعيد مسار ملف قائم — السياسة يجب أن تحمي الملف.
        photoInstaller: (String name, List<int> bytes) async => shared.path,
        photoSnapshot: () async => <String>{shared.path},
      ).restoreFull(zip),
      throwsA(isA<BackupApplyException>()),
    );
    expect(shared.existsSync(), isTrue, reason: 'الملف السابق لم يُحذف');
    expect(shared.readAsBytesSync(), <int>[7], reason: 'ولم تُكتب فوقه بايتات');
  });

  test('ملف يشير إليه سجل قائم في القاعدة لا يُحذف بعد الفشل', () async {
    final AppDb db = await _db();
    addTearDown(db.close);
    final File used = File(p.join(dir.path, 'used.jpg'));
    await used.writeAsBytes(<int>[5]);
    final Student old = await db.select(db.students).getSingle();
    await (db.update(db.students)..where((Students s) => s.id.equals(old.id)))
        .write(StudentsCompanion(photoPath: Value(used.path)));

    final Uint8List zip = _zipOf(
      _manifest()..['holidays'] = <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'date': '2026-09-20', 'title': 'أ'},
        <String, Object?>{'id': 2, 'date': '2026-09-20', 'title': 'مكرر'},
      ],
      photos: <String, List<int>>{
        'photos/1.jpg': <int>[1, 2, 3],
      },
    );

    await expectLater(
      BackupService(
        db,
        photoInstaller: (String name, List<int> bytes) async => used.path,
        photoSnapshot: () async => <String>{}, // لم يكن «معروفاً» قبل العملية
      ).restoreFull(zip),
      throwsA(isA<BackupApplyException>()),
    );
    expect(used.existsSync(), isTrue, reason: 'سجل قائم يشير إليه ⇒ لا حذف');
  });

  test('تعذّر قراءة قائمة الصور السابقة يوقف التنظيف بدل المخاطرة', () async {
    final AppDb db = await _db();
    addTearDown(db.close);
    final File orphan = File(p.join(dir.path, 'orphan.jpg'));
    final Uint8List zip = _zipOf(
      _manifest()..['holidays'] = <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'date': '2026-09-20', 'title': 'أ'},
        <String, Object?>{'id': 2, 'date': '2026-09-20', 'title': 'مكرر'},
      ],
      photos: <String, List<int>>{
        'photos/1.jpg': <int>[1, 2, 3],
      },
    );

    await expectLater(
      BackupService(
        db,
        photoInstaller: (String name, List<int> bytes) async {
          await orphan.writeAsBytes(bytes);
          return orphan.path;
        },
        photoSnapshot: () async => throw StateError('لا مجلد مستندات'),
      ).restoreFull(zip),
      throwsA(
        isA<BackupApplyException>().having(
          (BackupApplyException e) => e.message,
          'message',
          contains('تعذّرت قراءة قائمة الصور السابقة'),
        ),
      ),
    );
    expect(orphan.existsSync(), isTrue, reason: 'بلا معرفة السابق: لا حذف');
  });

  test('نجاح الاستعادة يُبقي الصور الجديدة ويربطها بالسجلات', () async {
    final AppDb db = await _db();
    addTearDown(db.close);
    final Uint8List zip = _zipOf(_manifest(), photos: <String, List<int>>{
      'photos/1.jpg': <int>[4, 5, 6],
    });

    await BackupService(
      db,
      photoInstaller: installer,
      photoSnapshot: () async => <String>{},
    ).restoreFull(zip);

    final Student restored = await db.select(db.students).getSingle();
    expect(restored.fullName, 'طالب النسخة');
    final String? path = restored.photoPath;
    expect(path, isNotNull);
    expect(path, startsWith(dir.path));
    expect(File(path!).existsSync(), isTrue, reason: 'الصورة الجديدة باقية');
    expect(File(path).readAsBytesSync(), <int>[4, 5, 6]);
  });

  test('سياسة الحذف نقية: تُستثني الملفات السابقة والمستخدمة والمكررة', () {
    final List<String> out = BackupService.photosToDiscard(
      created: <String>['/p/new1.jpg', '/p/old.jpg', '/p/used.jpg', '/p/new1.jpg'],
      existedBefore: <String>{'/p/old.jpg'},
      referencedByRows: <String>{'/p/used.jpg'},
    );
    expect(out, <String>['/p/new1.jpg']);
    expect(
      BackupService.photosToDiscard(
        created: <String>['/p/new.jpg'],
        existedBefore: <String>{},
        referencedByRows: <String>{},
      ),
      <String>['/p/new.jpg'],
    );
  });
}
