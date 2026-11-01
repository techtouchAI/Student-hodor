/// تدقيق توافق صيغ النسخ 1 و2 و3 — ببيانات تحاكي ما كان التطبيق يصدّره فعلاً.
///
/// **مصدر الحقيقة للمخطط هو سجل هجرات `AppDb`**، لا حذف حقول من نسخة حديثة:
/// العمود الذي لم تُضفه أي هجرة كان في المخطط الأول (فكل نسخة حقيقية تحمله)،
/// والعمود الذي أضافته هجرة يغيب عن النسخ التي سبقتها:
///
/// | الهجرة | ما أُضيف |
/// |---|---|
/// | 2 | فهارس فقط (لا أعمدة) |
/// | 3 | `students.phone` |
/// | 4 | `attendance.arrivalTime` |
/// | 5 | جدول `alertNotifications` |
/// | 6 | جدول `lessons` + `sessions.lessonId` + `attendance.lessonId` + `leaves.fromSlot/toSlot` |
///
/// لذلك تُبنى نسخة v1 هنا بنقص هذه الحقول **وحدها**، وv2 بنقص حقول الحصص
/// وحدها، وv3 كاملة. أي حقل آخر يُعامل إلزامياً كما في المخطط الأصلي.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:student_hodor/data/backup_service.dart';
import 'package:student_hodor/data/db.dart';

Future<AppDb> _seed() async {
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
  for (int i = 1; i <= 2; i++) {
    await db.addStudent(yearId: yearId, classId: classId, fullName: 'طالب قائم $i');
  }
  return db;
}

/// نسخة v1 كما صدّرها التطبيق قبل الإصدار 6: JSON، بلا حصص، وبلا الحقول
/// التي أضفتها الهجرات 3 و4 و5.
Map<String, Object?> _v1Manifest() => <String, Object?>{
      'format': 'student-hodor-backup',
      'version': 1,
      'at': '2024-09-15T07:10:00.000',
      'settings': <String, Object?>{
        'school_name': 'مدرسة الرشيد',
        'director_name': 'أ. سعد',
      },
      'years': <Map<String, Object?>>[
        <String, Object?>{
          'id': 5,
          'name': '2024-2025',
          'start': '2024-09-01',
          'end': '2025-06-30',
          'active': true,
          'closed': false,
          'closedAt': null,
        },
      ],
      'classes': <Map<String, Object?>>[
        <String, Object?>{'id': 6, 'yearId': 5, 'grade': 'الثالث', 'section': 'أ'},
      ],
      'students': <Map<String, Object?>>[
        // بلا `phone` (الهجرة 3) وبلا صور في حاوية JSON.
        <String, Object?>{
          'id': 7,
          'yearId': 5,
          'classId': 6,
          'fullName': 'أحمد كريم',
          'personKey': 'أحمد كريم',
          'seq': 1,
          'photoPath': null,
          'createdAt': '2024-09-01T08:00:00.000',
        },
        <String, Object?>{
          'id': 8,
          'yearId': 5,
          'classId': 6,
          'fullName': 'زيد علي',
          'personKey': 'زيد علي',
          'seq': 2,
          'photoPath': null,
          'createdAt': '2024-09-01T08:05:00.000',
        },
      ],
      'badges': <Map<String, Object?>>[
        <String, Object?>{
          'id': 9,
          'studentId': 7,
          'code': 'BDG-001',
          'version': 1,
          'status': 0,
          'issuedAt': '2024-09-02T09:00:00.000',
        },
      ],
      'sessions': <Map<String, Object?>>[
        // بلا `lessonId` (الهجرة 6).
        <String, Object?>{
          'id': 10,
          'yearId': 5,
          'classId': 6,
          'date': '2024-09-02',
          'openedAt': '2024-09-02T08:00:00.000',
          'closedAt': '2024-09-02T12:30:00.000',
        },
      ],
      'attendance': <Map<String, Object?>>[
        // بلا `lessonId` وبلا `arrivalTime` (الهجرة 4).
        <String, Object?>{
          'id': 11,
          'yearId': 5,
          'classId': 6,
          'studentId': 7,
          'date': '2024-09-02',
          'status': 0,
          'source': 0,
          'sessionId': 10,
          'note': null,
        },
        <String, Object?>{
          'id': 12,
          'yearId': 5,
          'classId': 6,
          'studentId': 8,
          'date': '2024-09-02',
          'status': 1,
          'source': 2,
          'sessionId': null,
          'note': 'تأخر الحافلة',
        },
      ],
      'scanEvents': <Map<String, Object?>>[
        <String, Object?>{
          'id': 13,
          'sessionId': 10,
          'code': 'BDG-001',
          'studentId': 7,
          'result': 0,
          'at': '2024-09-02T08:02:00.000',
        },
        <String, Object?>{
          'id': 14,
          'sessionId': null,
          'code': 'UNKNOWN',
          'studentId': null,
          'result': 2,
          'at': '2024-09-02T08:03:00.000',
        },
      ],
      'leaves': <Map<String, Object?>>[
        // بلا `fromSlot`/`toSlot` (الهجرة 6) ⇒ إجازة اليوم كله.
        <String, Object?>{
          'id': 15,
          'yearId': 5,
          'studentId': 8,
          'start': '2024-09-03',
          'end': '2024-09-04',
          'type': 0,
          'reason': 'مرض',
          'createdAt': '2024-09-02T20:00:00.000',
        },
      ],
      'holidays': <Map<String, Object?>>[
        <String, Object?>{'id': 16, 'date': '2024-09-20', 'title': 'عطلة رسمية'},
      ],
      'auditLogs': <Map<String, Object?>>[
        <String, Object?>{
          'id': 17,
          'at': '2024-09-01T08:00:00.000',
          'actor': 'local',
          'action': 'year_add',
          'details': '2024-2025',
        },
      ],
    };

/// نسخة v2: حاوية zip بصور، وبلا حقول الحصص وحدها.
Map<String, Object?> _v2Manifest() => <String, Object?>{
      'format': 'student-hodor-backup',
      'version': 2,
      'at': '2025-10-01T06:45:00.000',
      'settings': <String, Object?>{'school_name': 'مدرسة النور'},
      'years': <Map<String, Object?>>[
        <String, Object?>{
          'id': 1,
          'name': '2025-2026',
          'start': '2025-09-01',
          'end': '2026-06-30',
          'active': false,
          'closed': true,
          'closedAt': '2026-07-01T10:00:00.000',
        },
      ],
      'classes': <Map<String, Object?>>[
        <String, Object?>{'id': 2, 'yearId': 1, 'grade': 'الخامس', 'section': 'ب'},
      ],
      'students': <Map<String, Object?>>[
        <String, Object?>{
          'id': 3,
          'yearId': 1,
          'classId': 2,
          'fullName': 'ليلى حسن',
          'personKey': 'ليلى حسن',
          'seq': 1,
          'photoPath': '/old/device/photos/st-1-3.jpg',
          'phone': '07701234567',
          'createdAt': '2025-09-01T07:00:00.000',
        },
        <String, Object?>{
          'id': 4,
          'yearId': 1,
          'classId': 2,
          'fullName': 'محمد صالح',
          'personKey': 'محمد صالح',
          'seq': 2,
          'photoPath': null,
          'phone': null,
          'createdAt': '2025-09-01T07:01:00.000',
        },
      ],
      'badges': <Map<String, Object?>>[],
      'sessions': <Map<String, Object?>>[
        <String, Object?>{
          'id': 5,
          'yearId': 1,
          'classId': 2,
          'date': '2025-09-02',
          'openedAt': '2025-09-02T08:00:00.000',
          'closedAt': null,
        },
      ],
      'attendance': <Map<String, Object?>>[
        <String, Object?>{
          'id': 6,
          'yearId': 1,
          'classId': 2,
          'studentId': 3,
          'date': '2025-09-02',
          'status': 3,
          'source': 0,
          'sessionId': 5,
          'note': null,
          'arrivalTime': '07:55',
        },
      ],
      'scanEvents': <Map<String, Object?>>[],
      'leaves': <Map<String, Object?>>[
        <String, Object?>{
          'id': 7,
          'yearId': 1,
          'studentId': 4,
          'start': '2025-09-03',
          'end': '2025-09-03',
          'type': 1,
          'reason': '',
          'createdAt': '2025-09-02T19:00:00.000',
        },
      ],
      'holidays': <Map<String, Object?>>[],
      'alertNotifications': <Map<String, Object?>>[
        <String, Object?>{
          'id': 8,
          'yearId': 1,
          'studentId': 3,
          'kind': 'threshold_2',
          'absentDays': 3,
          'recordedDays': 10,
          'thresholdDays': 3.0,
          'occurredAt': '2025-10-01T06:40:00.000',
          'read': false,
          'readAt': null,
          'systemShown': true,
        },
      ],
      'auditLogs': <Map<String, Object?>>[],
    };

Uint8List _jsonOf(Map<String, Object?> manifest) =>
    Uint8List.fromList(utf8.encode(jsonEncode(manifest)));

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

Future<void> _expectFkClean(AppDb db, String after) async {
  expect(
    (await db.customSelect('PRAGMA foreign_keys').getSingle()).data.values.first,
    1,
    reason: 'التفعيل مفعّل — $after',
  );
  expect(
    await db.customSelect('PRAGMA foreign_key_check').get(),
    isEmpty,
    reason: 'لا مخالفات مراجع — $after',
  );
}

/// بصمة القاعدة: عدد الصفوف في كل جدول + الإعدادات. تكشف أي كتابة جزئية.
Future<Map<String, Object?>> _fingerprint(AppDb db) async => <String, Object?>{
      'years': (await db.select(db.academicYears).get()).length,
      'classes': (await db.select(db.schoolClasses).get()).length,
      'students': (await db.select(db.students).get()).length,
      'badges': (await db.select(db.badges).get()).length,
      'lessons': (await db.select(db.lessons).get()).length,
      'sessions': (await db.select(db.sessions).get()).length,
      'attendance': (await db.select(db.attendanceRows).get()).length,
      'scanEvents': (await db.select(db.scanEvents).get()).length,
      'leaves': (await db.select(db.leaves).get()).length,
      'holidays': (await db.select(db.holidays).get()).length,
      'alerts': (await db.select(db.alertNotifications).get()).length,
      'settings': await db.allSettings(),
    };

void main() {
  test('نسخة v1 حقيقية: كل سجل يعود كما هو، والحقول المستحدثة تأخذ دلالتها', () async {
    final AppDb db = await _seed();
    addTearDown(db.close);
    final Uint8List bytes = _jsonOf(_v1Manifest());

    final BackupInfo info = await BackupService(db).inspect(bytes);
    expect(info.version, 1);
    expect(info.legacyLessons, isTrue);
    expect(info.photoCount, 0);
    expect(info.counts['students'], 2);
    expect(info.counts['attendance'], 2);
    expect(info.counts['scan_events'], 2);
    expect(info.createdAt, DateTime.parse('2024-09-15T07:10:00.000'));

    await BackupService(db).restoreFull(bytes);

    // 1) لا فقدان: الأعداد والمعرّفات نفسها.
    expect(await db.select(db.academicYears).get(), hasLength(1));
    expect(await db.select(db.schoolClasses).get(), hasLength(1));
    expect(await db.select(db.badges).get(), hasLength(1));
    expect(await db.select(db.scanEvents).get(), hasLength(2));
    expect(await db.select(db.holidays).get(), hasLength(1));
    expect(await db.select(db.leaves).get(), hasLength(1));

    final List<Student> kids = await (db.select(db.students)
          ..orderBy(<OrderClauseGenerator<Students>>[
            (Students s) => OrderingTerm.asc(s.id),
          ]))
        .get();
    expect(kids.map((Student s) => s.id), <int>[7, 8]);
    expect(kids[0].fullName, 'أحمد كريم');
    expect(kids[0].personKey, 'أحمد كريم');
    expect(kids[1].seq, 2);
    expect(kids[0].phone, isNull, reason: 'الهجرة 3: لا هاتف في v1');
    expect(kids[0].createdAt, '2024-09-01T08:00:00.000');

    final Badge badge = (await db.select(db.badges).getSingle());
    expect(badge.id, 9);
    expect(badge.code, 'BDG-001');
    expect(badge.issuedAt, '2024-09-02T09:00:00.000');

    // 2) الحقول المستحدثة تأخذ دلالتها لا رقماً اعتباطياً.
    final int firstLesson = (await db.firstLesson()).id;
    expect(await db.lessonCount(), 6);
    expect((await db.select(db.sessions).getSingle()).lessonId, firstLesson);

    final List<AttendanceRow> rows = await (db.select(db.attendanceRows)
          ..orderBy(<OrderClauseGenerator<AttendanceRows>>[
            (AttendanceRows r) => OrderingTerm.asc(r.id),
          ]))
        .get();
    expect(rows.map((AttendanceRow r) => r.id), <int>[11, 12]);
    expect(rows.map((AttendanceRow r) => r.lessonId), <int>[firstLesson, firstLesson]);
    expect(rows.map((AttendanceRow r) => r.arrivalTime), <String?>[null, null]);
    expect(rows[1].note, 'تأخر الحافلة');
    expect(rows[1].source, AttendanceSource.autoClose);
    expect(rows[0].sessionId, 10);

    final Leave leave = await db.select(db.leaves).getSingle();
    expect(leave.fromSlot, isNull, reason: 'البند القديم = اليوم كله');
    expect(leave.toSlot, isNull);
    expect(leave.reason, 'مرض');
    expect(leave.type, 0);

    final List<ScanEvent> events = await (db.select(db.scanEvents)
          ..orderBy(<OrderClauseGenerator<ScanEvents>>[
            (ScanEvents e) => OrderingTerm.asc(e.id),
          ]))
        .get();
    expect(events.map((ScanEvent e) => e.code), <String>['BDG-001', 'UNKNOWN']);
    expect(events[1].studentId, isNull);
    expect(events[1].result, ScanResult.unknownCode);

    expect(
      (await db.select(db.holidays).getSingle()).title,
      'عطلة رسمية',
    );
    expect(await db.setting('school_name'), 'مدرسة الرشيد');
    expect(await db.setting('director_name'), 'أ. سعد');

    // 3) التدقيق: تاريخ الملف + سطر الاستعادة، والمعرّفات القديمة محفوظة.
    final List<AuditLog> audit = await (db.select(db.auditLogs)
          ..orderBy(<OrderClauseGenerator<AuditLogs>>[
            (AuditLogs a) => OrderingTerm.asc(a.id),
          ]))
        .get();
    expect(audit.any((AuditLog a) => a.id == 17 && a.action == 'year_add'), isTrue);
    expect(
      audit.where((AuditLog a) => a.action == 'backup_restore_full'),
      hasLength(1),
    );

    await _expectFkClean(db, 'بعد استعادة v1');
  });

  test('نسخة v2 حقيقية (zip بصور): الهاتف ووقت الوصول والتنبيهات تعود كما هي', () async {
    final AppDb db = await _seed();
    addTearDown(db.close);
    final Directory dir = Directory.systemTemp.createTempSync('hodor-compat-v2-');
    addTearDown(() => dir.deleteSync(recursive: true));

    final Uint8List bytes = _zipOf(
      _v2Manifest(),
      photos: <String, List<int>>{
        'photos/3.jpg': <int>[1, 2, 3, 4],
      },
    );

    final BackupInfo info = await BackupService(db).inspect(bytes);
    expect(info.version, 2);
    expect(info.legacyLessons, isTrue);
    expect(info.photoCount, 1);

    await BackupService(
      db,
      photoInstaller: (String name, List<int> b) async {
        final File f = File(p.join(dir.path, name));
        await f.writeAsBytes(b, flush: true);
        return f.path;
      },
      photoSnapshot: () async => <String>{},
    ).restoreFull(bytes);

    final List<Student> kids = await (db.select(db.students)
          ..orderBy(<OrderClauseGenerator<Students>>[
            (Students s) => OrderingTerm.asc(s.id),
          ]))
        .get();
    expect(kids.map((Student s) => s.fullName), <String>['ليلى حسن', 'محمد صالح']);
    expect(kids[0].phone, '07701234567', reason: 'الهجرة 3 موجودة في v2');
    expect(kids[1].phone, isNull);
    expect(kids[0].photoPath, isNotNull);
    expect(File(kids[0].photoPath!).existsSync(), isTrue);
    expect(
      File(kids[0].photoPath!).readAsBytesSync(),
      <int>[1, 2, 3, 4],
      reason: 'بايتات الصورة المضمّنة لا مسار الجهاز القديم',
    );

    final AttendanceRow row = await db.select(db.attendanceRows).getSingle();
    expect(row.arrivalTime, '07:55');
    expect(row.lessonId, (await db.firstLesson()).id);

    final Leave leave = await db.select(db.leaves).getSingle();
    expect(leave.fromSlot, isNull);
    expect(leave.toSlot, isNull);
    expect(leave.reason, '');

    final AlertNotification n = await db.select(db.alertNotifications).getSingle();
    expect(n.kind, 'threshold_2');
    expect(n.absentDays, 3);
    expect(n.recordedDays, 10);
    expect(n.thresholdDays, 3.0);
    expect(n.read, isFalse);
    expect(n.systemShown, isTrue);
    expect(n.readAt, isNull);

    final AcademicYear year = await db.select(db.academicYears).getSingle();
    expect(year.closed, isTrue, reason: 'سنة مقفلة في v2 تبقى مقفلة');
    expect(year.closedAt, '2026-07-01T10:00:00.000');

    await _expectFkClean(db, 'بعد استعادة v2');
  });

  test('نسخة v3 كاملة: كل صف يعود حرفياً بلا فقدان أي حقل', () async {
    final AppDb src = await _seed();
    addTearDown(src.close);
    final AcademicYear year = await src.select(src.academicYears).getSingle();
    final List<Student> kids = await src.select(src.students).get();
    await src.into(src.students).insert(
          StudentsCompanion.insert(
            yearId: year.id,
            classId: kids.first.classId,
            fullName: 'طالب ثالث',
            personKey: 'طالب ثالث',
            seq: 3,
            createdAt: '2026-09-01T09:00:00.000',
            phone: const Value('07801112223'),
          ),
        );
    final List<Student> all = await src.select(src.students).get();
    final List<Lesson> lessons = await src.allLessons();
    await src.upsertAttendance(
      yearId: year.id,
      classId: all.first.classId,
      studentId: all.first.id,
      date: '2026-09-02',
      lessonId: lessons[1].id,
      status: AttendanceStatus.late,
      source: AttendanceSource.scan,
      arrivalTime: '07:58',
    );
    await src.into(src.sessions).insert(
          SessionsCompanion.insert(
            yearId: year.id,
            classId: all.first.classId,
            date: '2026-09-02',
            lessonId: Value(lessons[1].id),
            openedAt: '2026-09-02T07:50:00.000',
            closedAt: const Value('2026-09-02T08:40:00.000'),
          ),
        );
    await src.into(src.leaves).insert(
          LeavesCompanion.insert(
            yearId: year.id,
            studentId: all[1].id,
            start: '2026-09-03',
            end: '2026-09-03',
            fromSlot: const Value(2),
            toSlot: const Value(3),
            type: 2,
            reason: const Value('موعد طبي'),
            createdAt: '2026-09-02T21:00:00.000',
          ),
        );
    await src.into(src.holidays).insert(
          HolidaysCompanion.insert(date: '2026-09-25', title: 'عطلة وطنية'),
        );
    await src.into(src.badges).insert(
          BadgesCompanion.insert(
            studentId: all.first.id,
            code: 'B-2026-1',
            issuedAt: '2026-09-03T08:00:00.000',
          ),
        );

    final Uint8List bytes = await BackupService(src).exportBytes();
    final Map<String, Object?> manifest = _manifestOf(bytes);
    expect(manifest['version'], BackupService.backupVersion);

    final AppDb dst = await _seed();
    addTearDown(dst.close);
    await BackupService(dst).restoreFull(bytes);

    Future<List<Map<String, Object?>>> dump(AppDb db) async {
      final List<DataClass> rows = <DataClass>[
        ...await db.select(db.academicYears).get(),
        ...await db.select(db.schoolClasses).get(),
        ...await db.select(db.students).get(),
        ...await db.select(db.badges).get(),
        ...await db.allLessons(),
        ...await db.select(db.sessions).get(),
        ...await db.select(db.attendanceRows).get(),
        ...await db.select(db.scanEvents).get(),
        ...await db.select(db.leaves).get(),
        ...await db.select(db.holidays).get(),
        ...await db.select(db.alertNotifications).get(),
      ];
      return rows.map((DataClass r) => r.toJson()).toList();
    }

    expect(await dump(dst), await dump(src), reason: 'لا فقدان ولا تحويل');
    expect(await dst.allSettings(), await src.allSettings());
    // سجل التدقيق يزيد سطراً واحداً (الاستعادة نفسها) ويحتفظ بتاريخ المصدر.
    final List<AuditLog> srcAudit = await src.select(src.auditLogs).get();
    final List<AuditLog> dstAudit = await dst.select(dst.auditLogs).get();
    expect(dstAudit.length, srcAudit.length + 1);
    expect(
      dstAudit.map((AuditLog a) => '${a.action}|${a.details}'),
      containsAll(srcAudit.map((AuditLog a) => '${a.action}|${a.details}')),
    );
    await _expectFkClean(dst, 'بعد استعادة v3');
  });

  test('أنواع غير صحيحة تُرفض قبل أي كتابة، برسالة تحدد القسم', () async {
    final Map<String, List<String>> cases = <String, List<String>>{
      'السنوات': <String>['active', 'نعم'],
      'الطلاب': <String>['id', 'abc'],
      'سجلات الحضور': <String>['status', 'غائب'],
      'الإجازات': <String>['type', 'x'],
    };
    for (final MapEntry<String, List<String>> c in cases.entries) {
      final AppDb db = await _seed();
      addTearDown(db.close);
      final Map<String, Object?> manifest = _v1Manifest();
      final List<Map<String, Object?>> rows =
          (manifest[_sectionKeyOf(c.key)]! as List<Object?>)
              .cast<Map<String, Object?>>();
      rows.first[c.value[0]] = c.value[1];
      manifest[_sectionKeyOf(c.key)] = rows;
      final Map<String, Object?> before = await _fingerprint(db);

      await expectLater(
        BackupService(db).restoreFull(_jsonOf(manifest)),
        throwsA(
          isA<BackupValidationException>().having(
            (BackupValidationException e) => e.message,
            'message',
            allOf(contains(c.key), contains('السطر 1')),
          ),
        ),
        reason: 'نوع خاطئ في ${c.key}',
      );
      expect(await _fingerprint(db), before, reason: 'لا كتابة عند الرفض');
    }
  });

  test('مراجع أجنبية يتيمة تُرفض قبل أي كتابة في كل قسم', () async {
    // `scanEvents.sessionId` عمود رقمي بلا مفتاح أجنبي في المخطط، فليس
    // مرجعاً قابلاً للتحقق — لا يُدرج هنا.
    for (final String section in <String>[
      'students',
      'badges',
      'sessions',
      'attendance',
      'leaves',
    ]) {
      final AppDb db = await _seed();
      final Map<String, Object?> manifest = _v1Manifest();
      final List<Map<String, Object?>> rows =
          (manifest[section]! as List<Object?>).cast<Map<String, Object?>>();
      final Map<String, Object?> first = rows.first;
      if (section == 'students') {
        first['classId'] = 999;
      } else if (section == 'badges') {
        first['studentId'] = 999;
      } else if (section == 'sessions') {
        first['classId'] = 999;
      } else if (section == 'attendance') {
        first['studentId'] = 999;
      } else {
        first['studentId'] = 999;
      }
      final Map<String, Object?> before = await _fingerprint(db);
      await expectLater(
        BackupService(db).restoreFull(_jsonOf(manifest)),
        throwsA(isA<BackupValidationException>()),
        reason: 'مرجع يتيم في $section',
      );
      expect(await _fingerprint(db), before, reason: 'لا كتابة في $section');
    }
  });

  test('حقل إلزامي في المخطط الأول (`closed`) لا يُخترع له افتراضي', () async {
    final AppDb db = await _seed();
    addTearDown(db.close);
    final Map<String, Object?> manifest = _v1Manifest();
    final List<Map<String, Object?>> years =
        (manifest['years']! as List<Object?>).cast<Map<String, Object?>>();
    years.first.remove('closed');
    final Map<String, Object?> before = await _fingerprint(db);

    await expectLater(
      BackupService(db).restoreFull(_jsonOf(manifest)),
      throwsA(
        isA<BackupValidationException>().having(
          (BackupValidationException e) => e.message,
          'message',
          contains('السنوات'),
        ),
      ),
      reason: '`closed` لم تُضف بأي هجرة ⇒ إلزامية، والرفض أأمن من اختراع قيمة',
    );
    expect(await _fingerprint(db), before);
  });
}

/// اسم القسم في البيان من اسمه العربي (لتوليد حالات النوع الخاطئ).
String _sectionKeyOf(String label) => switch (label) {
      'السنوات' => 'years',
      'الطلاب' => 'students',
      'سجلات الحضور' => 'attendance',
      'الإجازات' => 'leaves',
      _ => throw ArgumentError(label),
    };

Map<String, Object?> _manifestOf(Uint8List zip) {
  final Archive archive = ZipDecoder().decodeBytes(zip);
  final ArchiveFile file = archive.files.firstWhere(
    (ArchiveFile f) => f.name == BackupService.manifestName,
  );
  return jsonDecode(utf8.decode(file.content as List<int>))
      as Map<String, Object?>;
}
