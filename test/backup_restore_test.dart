/// الاستعادة الكاملة: **استبدال** لا دمج، وذرّية، وحماية البيانات الحالية.
///
/// يثبت هذا الملف ما هو جوهر القرار المعماري:
///  * الاستعادة تحذف كل ما لا يوجد في النسخة (سنوات/صفوف/طلاب/سجلات/إعدادات).
///  * الفحص وحده (`inspect`) لا يكتب شيئاً، والإلغاء صريح لا يمسّ البيانات.
///  * ملف تالف أو غير متسق يُرفض قبل أول كتابة.
///  * فشل أثناء التطبيق يتراجع كاملاً (لا قاعدة نصف مستعادة).
///  * الاستعادة المتزامنة مرفوضة، والاستعادة المتكررة لا تضاعف.
///  * بعد كل استعادة: `PRAGMA foreign_keys = 1` و`foreign_key_check` فارغ.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/lesson.dart';
import 'package:student_hodor/data/backup_service.dart';
import 'package:student_hodor/data/db.dart';

/// سنة + صف + طالب، مع إعدادات تميّز القاعدة عن غيرها.
Future<({AppDb db, int yearId, int classId, int studentId})> _seed({
  required String schoolName,
  required String studentName,
  String grade = 'السادس',
  String section = 'أ',
  String yearName = '2026-2027',
  bool active = true,
}) async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await db.setSetting('school_name', schoolName);
  await db.setSetting('director_name', 'مدير $schoolName');
  final int yearId = await db.into(db.academicYears).insert(
        AcademicYearsCompanion(
          name: Value(yearName),
          start: const Value('2026-09-01'),
          end: const Value('2027-06-30'),
          active: Value(active),
        ),
      );
  final int classId = await db.into(db.schoolClasses).insert(
        SchoolClassesCompanion(
          yearId: Value(yearId),
          grade: Value(grade),
          section: Value(section),
        ),
      );
  final int studentId = await db.addStudent(
    yearId: yearId,
    classId: classId,
    fullName: studentName,
    phone: '07701234567',
  );
  return (db: db, yearId: yearId, classId: classId, studentId: studentId);
}

/// حالة القاعدة كلها — للمقارنة الصارمة قبل/بعد أي محاولة.
Future<Map<String, Object?>> _stateOf(AppDb db) async {
  List<Map<String, Object?>> rows(List<DataClass> r) =>
      <Map<String, Object?>>[for (final DataClass x in r) x.toJson()];
  return <String, Object?>{
    'settings': await db.allSettings(),
    'years': rows(await db.select(db.academicYears).get()),
    'classes': rows(await db.select(db.schoolClasses).get()),
    'students': rows(await db.select(db.students).get()),
    'badges': rows(await db.select(db.badges).get()),
    'sessions': rows(await db.select(db.sessions).get()),
    'attendance': rows(await db.select(db.attendanceRows).get()),
    'scanEvents': rows(await db.select(db.scanEvents).get()),
    'leaves': rows(await db.select(db.leaves).get()),
    'holidays': rows(await db.select(db.holidays).get()),
    'lessons': rows(await db.select(db.lessons).get()),
    'alerts': rows(await db.select(db.alertNotifications).get()),
    'auditLogs': rows(await db.select(db.auditLogs).get()),
  };
}

Future<void> _expectFkClean(AppDb db, String after) async {
  final QueryRow fk = await db.customSelect('PRAGMA foreign_keys').getSingle();
  expect(fk.data.values.first, 1, reason: 'التفعيل على الاتصال — $after');
  expect(
    await db.customSelect('PRAGMA foreign_key_check').get(),
    isEmpty,
    reason: 'لا صفوف مخالفة — $after',
  );
}

Future<Map<String, Object?>> _manifestOf(AppDb db) async {
  final Uint8List zip = await BackupService(db).exportBytes();
  final Archive archive = ZipDecoder().decodeBytes(zip);
  final ArchiveFile file = archive.files.firstWhere(
    (ArchiveFile f) => f.name == BackupService.manifestName,
  );
  return jsonDecode(utf8.decode(file.content as List<int>))
      as Map<String, Object?>;
}

Uint8List _zipOf(Map<String, Object?> manifest) {
  final Archive archive = Archive();
  final List<int> bytes = utf8.encode(jsonEncode(manifest));
  archive.addFile(ArchiveFile(BackupService.manifestName, bytes.length, bytes));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Uint8List _jsonBytes(Map<String, Object?> manifest) =>
    Uint8List.fromList(utf8.encode(jsonEncode(manifest)));

Map<String, Object?> _manifestShell({
  int version = BackupService.backupVersion,
}) =>
    <String, Object?>{
      'format': 'student-hodor-backup',
      'version': version,
      'at': '2026-09-18T09:30:00.000',
      'settings': <String, Object?>{'school_name': 'مدرسة النسخة'},
      'years': <Map<String, Object?>>[
        <String, Object?>{
          'id': 50,
          'name': '2027-2028',
          'start': '2027-09-01',
          'end': '2028-06-30',
          'active': true,
          'closed': false,
          'closedAt': null,
        },
      ],
      'classes': <Map<String, Object?>>[
        <String, Object?>{
          'id': 60,
          'yearId': 50,
          'grade': 'الخامس',
          'section': 'ب',
        },
      ],
      'students': <Map<String, Object?>>[
        <String, Object?>{
          'id': 70,
          'yearId': 50,
          'classId': 60,
          'fullName': 'طالب النسخة',
          'personKey': 'طالب النسخة',
          'seq': 1,
          'photoPath': null,
          'phone': null,
          'createdAt': '2026-09-01T08:00:00.000',
        },
      ],
    };

void main() {
  test('الاستعادة تستبدل البيانات الحالية ببيانات النسخة (لا دمج)', () async {
    final ({AppDb db, int yearId, int classId, int studentId}) src = await _seed(
      schoolName: 'مدرسة النسخة',
      studentName: 'طالب النسخة',
    );
    addTearDown(src.db.close);
    await src.db.upsertAttendance(
      yearId: src.yearId,
      classId: src.classId,
      studentId: src.studentId,
      date: '2026-09-03',
      lessonId: (await src.db.firstLesson()).id,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
    );
    await src.db.into(src.db.holidays).insert(
          const HolidaysCompanion(
            date: Value('2026-10-01'),
            title: Value('عطلة النسخة'),
          ),
        );
    final Uint8List zip = await BackupService(src.db).exportBytes();

    final ({AppDb db, int yearId, int classId, int studentId}) dst = await _seed(
      schoolName: 'مدرسة قديمة',
      studentName: 'طالب قديم',
      grade: 'الرابع',
      section: 'ج',
      yearName: '2025-2026',
    );
    addTearDown(dst.db.close);
    // بيانات إضافية لا وجود لها في النسخة: يجب أن تختفي بعد الاستعادة.
    await dst.db.addStudent(
      yearId: dst.yearId,
      classId: dst.classId,
      fullName: 'طالب زائد',
    );
    await dst.db.upsertAttendance(
      yearId: dst.yearId,
      classId: dst.classId,
      studentId: dst.studentId,
      date: '2026-09-04',
      lessonId: (await dst.db.firstLesson()).id,
      status: AttendanceStatus.absent,
      source: AttendanceSource.manual,
    );
    await dst.db.into(dst.db.holidays).insert(
          const HolidaysCompanion(
            date: Value('2026-11-01'),
            title: Value('عطلة قديمة'),
          ),
        );

    final BackupInfo info =
        await BackupService(dst.db).inspect(zip);
    expect(info.version, BackupService.backupVersion);
    expect(info.legacyLessons, isFalse);
    expect(info.counts['students'], 1);
    expect(info.counts['attendance'], 1);
    expect(info.createdAt, isNotNull);
    expect(info.photoCount, 0);

    await BackupService(dst.db).restoreFull(zip);

    final List<Student> students =
        await dst.db.select(dst.db.students).get();
    expect(
      <String>[for (final Student s in students) s.fullName],
      <String>['طالب النسخة'],
      reason: 'الطلاب القدامى لا يبقون والجديد يُضاف',
    );
    expect(await dst.db.select(dst.db.schoolClasses).get(), hasLength(1));
    expect(
      (await dst.db.select(dst.db.schoolClasses).getSingle()).grade,
      'السادس',
      reason: 'الصفوف القديمة (الرابع/ج) استُبدلت',
    );
    expect((await dst.db.activeYear())!.name, '2026-2027');
    expect(await dst.db.setting('school_name'), 'مدرسة النسخة');
    expect(
      await dst.db.setting('director_name'),
      'مدير مدرسة النسخة',
      reason: 'الإعدادات أيضاً تُستبدل لا تُدمج',
    );
    expect(await dst.db.select(dst.db.holidays).get(), hasLength(1));
    expect(
      (await dst.db.select(dst.db.holidays).getSingle()).title,
      'عطلة النسخة',
    );
    final List<AttendanceRow> attendance =
        await dst.db.select(dst.db.attendanceRows).get();
    expect(attendance, hasLength(1));
    expect(attendance.single.date, '2026-09-03');
    expect(
      (await dst.db.select(dst.db.auditLogs).get())
          .any((AuditLog l) => l.action == 'backup_restore_full'),
      isTrue,
      reason: 'العملية تُسجَّل في التدقيق',
    );
    await _expectFkClean(dst.db, 'بعد استعادة كاملة');
  });

  test('الفحص وحده لا يكتب شيئاً، ولا تُلمس البيانات قبل التأكيد', () async {
    final ({AppDb db, int yearId, int classId, int studentId}) dst = await _seed(
      schoolName: 'مدرسة قديمة',
      studentName: 'طالب قديم',
    );
    addTearDown(dst.db.close);
    final Map<String, Object?> before = await _stateOf(dst.db);
    final Uint8List zip = _zipOf(_manifestShell());

    final BackupInfo info = await BackupService(dst.db).inspect(zip);
    expect(info.counts['years'], 1);
    expect(info.counts['students'], 1);
    expect(await _stateOf(dst.db), before);
    await _expectFkClean(dst.db, 'بعد الفحص وحده');

    // «إلغاء» في الواجهة = عدم استدعاء restoreFull: لا تغيير.
    expect(await _stateOf(dst.db), before);
  });

  test('ملفات غير صالحة تُرفض قبل أي كتابة ولا تغيّر صفاً', () async {
    final ({AppDb db, int yearId, int classId, int studentId}) dst = await _seed(
      schoolName: 'مدرسة قديمة',
      studentName: 'طالب قديم',
    );
    addTearDown(dst.db.close);
    final Map<String, Object?> before = await _stateOf(dst.db);

    final List<Uint8List> invalid = <Uint8List>[
      Uint8List(0),
      Uint8List.fromList(utf8.encode('ليس نسخة احتياطية')),
      _jsonBytes(<String, Object?>{'format': 'other-app', 'version': 3}),
      _jsonBytes(<String, Object?>{'format': 'student-hodor-backup', 'version': 0}),
      _jsonBytes(<String, Object?>{'format': 'student-hodor-backup', 'version': 3, 'attendance': 'x'}),
    ];

    final Map<String, Object?> orphan = _manifestShell();
    orphan['attendance'] = <Map<String, Object?>>[
      <String, Object?>{
        'id': 1,
        'yearId': 50,
        'classId': 60,
        'studentId': 999,
        'date': '2026-09-03',
        'lessonId': 1,
        'status': 0,
        'source': 0,
        'sessionId': null,
        'note': null,
        'arrivalTime': null,
      },
    ];
    invalid.add(_zipOf(orphan));

    final Map<String, Object?> missingLesson = _manifestShell();
    missingLesson['lessons'] = <Map<String, Object?>>[
      <String, Object?>{
        'id': 1,
        'slot': 1,
        'name': 'الحصة الأولى',
        'start': '08:00',
        'end': '08:45',
      },
    ];
    final Map<String, Object?> rowWithoutLesson = <String, Object?>{
      'id': 1,
      'yearId': 50,
      'classId': 60,
      'studentId': 70,
      'date': '2026-09-03',
      'status': 0,
      'source': 0,
      'sessionId': null,
      'note': null,
      'arrivalTime': null,
    };
    missingLesson['attendance'] = <Map<String, Object?>>[rowWithoutLesson];
    invalid.add(_zipOf(missingLesson));

    for (final Uint8List bytes in invalid) {
      await expectLater(
        BackupService(dst.db).inspect(bytes),
        throwsA(isA<Exception>()),
        reason: 'الملف التالف يُرفض في الفحص',
      );
      await expectLater(
        BackupService(dst.db).restoreFull(bytes),
        throwsA(isA<Exception>()),
      );
    }
    expect(await _stateOf(dst.db), before, reason: 'لا كتابة ولا حذف');
    await _expectFkClean(dst.db, 'بعد رفض ملفات تالفة');
  });

  test('فشل أثناء التطبيق يتراجع كاملاً: لا قاعدة نصف مستعادة', () async {
    final ({AppDb db, int yearId, int classId, int studentId}) src = await _seed(
      schoolName: 'مدرسة النسخة',
      studentName: 'طالب النسخة',
    );
    addTearDown(src.db.close);
    await src.db.into(src.db.holidays).insert(
          const HolidaysCompanion(
            date: Value('2026-10-01'),
            title: Value('عطلة 1'),
          ),
        );
    await src.db.into(src.db.holidays).insert(
          const HolidaysCompanion(
            date: Value('2026-10-02'),
            title: Value('عطلة 2'),
          ),
        );
    final Map<String, Object?> manifest = await _manifestOf(src.db);
    // خلل يمرّ من التحقق (معرّفات فريدة) ويخرق قيد التفرّد في القاعدة نفسها:
    // تاريخا عطلتين متساويان. الإدراج يفشل **بعد** كتابة الحصص والسنوات
    // والصفوف والطلاب — وهو ما يجب أن يتراجع كله.
    final List<Map<String, Object?>> holidays =
        (manifest['holidays']! as List<Object?>).cast<Map<String, Object?>>();
    holidays[1]['date'] = holidays[0]['date'];

    final ({AppDb db, int yearId, int classId, int studentId}) dst = await _seed(
      schoolName: 'مدرسة قديمة',
      studentName: 'طالب قديم',
    );
    addTearDown(dst.db.close);
    await dst.db.upsertAttendance(
      yearId: dst.yearId,
      classId: dst.classId,
      studentId: dst.studentId,
      date: '2026-09-04',
      lessonId: (await dst.db.firstLesson()).id,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
    );
    final Map<String, Object?> before = await _stateOf(dst.db);

    await expectLater(
      BackupService(dst.db).restoreFull(_zipOf(manifest)),
      throwsA(
        isA<BackupApplyException>().having(
          (BackupApplyException e) => e.message,
          'message',
          contains('أُعيدت بياناتك السابقة'),
        ),
      ),
    );

    expect(
      await _stateOf(dst.db),
      before,
      reason: 'المعاملة تراجعت كاملة: كل الجداول كما كانت',
    );
    await _expectFkClean(dst.db, 'بعد فشل منتصف الاستعادة');
  });

  test('الاستعادة المتزامنة مرفوضة، والحارس يُحرَّر بعد الانتهاء', () async {
    final ({AppDb db, int yearId, int classId, int studentId}) src = await _seed(
      schoolName: 'مدرسة النسخة',
      studentName: 'طالب النسخة',
    );
    addTearDown(src.db.close);
    final Uint8List zip = await BackupService(src.db).exportBytes();

    final ({AppDb db, int yearId, int classId, int studentId}) dst = await _seed(
      schoolName: 'مدرسة قديمة',
      studentName: 'طالب قديم',
    );
    addTearDown(dst.db.close);

    final BackupService svc = BackupService(dst.db);
    final Future<void> first = svc.restoreFull(zip);
    await expectLater(
      svc.restoreFull(zip),
      throwsA(isA<StateError>()),
      reason: 'لا استعادتان متزامنتان على القاعدة نفسها',
    );
    await first;
    expect(
      (await dst.db.select(dst.db.students).getSingle()).fullName,
      'طالب النسخة',
    );

    // الحارس تحرّر: استعادة ثالثة تعمل وتظل استبدالاً لا تكراراً.
    await svc.restoreFull(zip);
    expect(await dst.db.select(dst.db.students).get(), hasLength(1));
    await _expectFkClean(dst.db, 'بعد استعادة متزامنة ثم تكرار');
  });

  test('نسخة فارغة (بلا سنوات) تستبدل البيانات وتُبقي جدول حصص صالحاً',
      () async {
    final AppDb empty = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(empty.close);
    await empty.setSetting('school_name', 'مدرسة فارغة');
    final Uint8List zip = await BackupService(empty).exportBytes();

    final ({AppDb db, int yearId, int classId, int studentId}) dst = await _seed(
      schoolName: 'مدرسة قديمة',
      studentName: 'طالب قديم',
    );
    addTearDown(dst.db.close);
    await BackupService(dst.db).restoreFull(zip);

    expect(await dst.db.activeYear(), isNull, reason: 'لا سنوات بعد الاستبدال');
    expect(await dst.db.select(dst.db.students).get(), isEmpty);
    expect(await dst.db.select(dst.db.attendanceRows).get(), isEmpty);
    expect(
      await dst.db.lessonCount(),
      LessonSchedule.defaultCount,
      reason: 'جدول الحصص الافتراضي يبقى صالحاً فلا تتعطل الشاشات',
    );
    expect(await dst.db.setting('school_name'), 'مدرسة فارغة');
    await _expectFkClean(dst.db, 'بعد استعادة نسخة فارغة');
  });

  test('نسخة v1 (JSON بلا حصص): استبدال كامل وترحيل الحصص الافتراضية', () async {
    final Map<String, Object?> v1 = <String, Object?>{
      'format': 'student-hodor-backup',
      'version': 1,
      'settings': <String, Object?>{'school_name': 'مدرسة قديمة جداً'},
      'years': <Map<String, Object?>>[
        <String, Object?>{
          'id': 5,
          'name': '2024-2025',
          'start': '2024-09-01',
          'end': '2025-06-30',
          'active': true,
        },
      ],
      'classes': <Map<String, Object?>>[
        <String, Object?>{'id': 6, 'yearId': 5, 'grade': 'الثالث', 'section': 'أ'},
      ],
      'students': <Map<String, Object?>>[
        <String, Object?>{
          'id': 7,
          'yearId': 5,
          'classId': 6,
          'fullName': 'طالب v1',
          'personKey': 'طالب v1',
          'seq': 1,
          'createdAt': '2024-09-01T08:00:00.000',
        },
      ],
      'sessions': <Map<String, Object?>>[
        <String, Object?>{
          'id': 8,
          'yearId': 5,
          'classId': 6,
          'date': '2024-09-02',
          'openedAt': '2024-09-02T08:00:00.000',
          'closedAt': '2024-09-02T12:00:00.000',
        },
      ],
      'attendance': <Map<String, Object?>>[
        <String, Object?>{
          'id': 9,
          'yearId': 5,
          'classId': 6,
          'studentId': 7,
          'date': '2024-09-02',
          'status': 0,
          'source': 0,
        },
      ],
    };

    final ({AppDb db, int yearId, int classId, int studentId}) dst = await _seed(
      schoolName: 'مدرسة قديمة',
      studentName: 'طالب قديم',
    );
    addTearDown(dst.db.close);
    final Uint8List bytes = _jsonBytes(v1);
    final BackupInfo info = await BackupService(dst.db).inspect(bytes);
    expect(info.version, 1);
    expect(info.legacyLessons, isTrue);

    await BackupService(dst.db).restoreFull(bytes);

    expect(await dst.db.select(dst.db.students).get(), hasLength(1));
    expect(
      (await dst.db.select(dst.db.students).getSingle()).fullName,
      'طالب v1',
    );
    expect(await dst.db.setting('school_name'), 'مدرسة قديمة جداً');
    final int firstLessonId = (await dst.db.firstLesson()).id;
    expect(
      (await dst.db.select(dst.db.sessions).getSingle()).lessonId,
      firstLessonId,
      reason: 'ترحيل الصيغة 1 الرسمي: السطر القديم = الحصة الأولى',
    );
    expect(
      (await dst.db.select(dst.db.attendanceRows).getSingle()).lessonId,
      firstLessonId,
    );
    await _expectFkClean(dst.db, 'بعد استعادة نسخة v1');
  });
}
