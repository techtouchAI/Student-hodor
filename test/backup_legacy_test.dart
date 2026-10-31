/// T1: توافق النسخ الاحتياطية والدمج مع بُعد الحصص.
///
/// يغطي ما كان بلا اختبار: نسخة **v2** بلا جدول حصص، ونسخة v3 بالحصص
/// والإجازات، والدمج (حصتان في اليوم نفسه، ومنع التكرار، وإسقاط الحصة
/// المفقودة على الأولى، وتجاهل الأسطر التي تشير إلى طالب غير موجود).
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/lesson.dart';
import 'package:student_hodor/data/backup_service.dart';
import 'package:student_hodor/data/db.dart';

/// سنة + صف + طالبان (المعرّفات نفسها في كل قاعدة تُبنى بهذه الدالة).
Future<({AppDb db, int classId, List<Student> kids})> _seed() async {
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
    await db.addStudent(yearId: yearId, classId: classId, fullName: 'طالب $i');
  }
  final List<Student> kids = await (db.select(db.students)
        ..orderBy(<OrderClauseGenerator<Students>>[
          (Students s) => OrderingTerm.asc(s.id),
        ]))
      .get();
  return (db: db, classId: classId, kids: kids);
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

List<Map<String, Object?>> _rows(Object? v) =>
    (v as List<Object?>? ?? <Object?>[]).cast<Map<String, Object?>>();

/// مفتاح السطر بالصيغة المعطاة أياً كانت كتابته (`lesson_id` أو `lessonId`):
/// صيغة مفاتيح JSON تتبع الكود المولَّد، والاختبار لا يفترضها.
String? _keyLike(Map<String, Object?> row, String wanted) {
  final String norm = wanted.replaceAll('_', '').toLowerCase();
  for (final String k in row.keys) {
    if (k.replaceAll('_', '').toLowerCase() == norm) {
      return k;
    }
  }
  return null;
}

/// نسخة من السطر بقيم مستبدلة، مع مطابقة المفتاح بأي صيغة.
Map<String, Object?> _with(
  Map<String, Object?> row,
  Map<String, Object?> overrides,
) {
  final Map<String, Object?> out = Map<String, Object?>.of(row);
  overrides.forEach((String k, Object? v) {
    out[_keyLike(out, k) ?? k] = v;
  });
  return out;
}

/// حذف عمود من سطر بيان قديم (بأي صيغة كتابة).
void _drop(Map<String, Object?> row, String key) {
  final String? k = _keyLike(row, key);
  if (k != null) {
    row.remove(k);
  }
}

void main() {

  test('نسخة بصيغة أحدث من التطبيق تُرفض قبل أي مسح أو استعادة', () async {
    final ({AppDb db, int classId, List<Student> kids}) seed = await _seed();
    final AppDb db = seed.db;
    addTearDown(db.close);
    final Map<String, Object?> manifest = await _manifestOf(db);
    manifest['version'] = BackupService.backupVersion + 1;

    await expectLater(
      BackupService(db).restoreFull(_zipOf(manifest)),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          allOf(
            contains('${BackupService.backupVersion + 1}'),
            contains('حدّث التطبيق'),
          ),
        ),
      ),
      reason: 'الصيغة المستقبلية تُرفض برسالة صريحة، لا باستعادة جزئية صامتة',
    );

    // لم يُحذف شيء: القاعدة كما كانت قبل المحاولة.
    expect(await db.select(db.students).get(), hasLength(2));
    expect(await db.select(db.schoolClasses).get(), hasLength(1));
    expect(await db.activeYear(), isNotNull);
  });

  test('نسخة بلا رقم صيغة (صيغة 1) تُقبل وتُستعاد كاملة', () async {
    final ({AppDb db, int classId, List<Student> kids}) seed = await _seed();
    final Map<String, Object?> manifest = await _manifestOf(seed.db);
    await seed.db.close();
    manifest.remove('version');

    final AppDb dst = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(dst.close);
    await BackupService(dst).restoreFull(_zipOf(manifest));
    expect(await dst.select(dst.students).get(), hasLength(2));
  });

  test('الدمج يرفض أيضاً نسخة بصيغة أحدث', () async {
    final ({AppDb db, int classId, List<Student> kids}) seed = await _seed();
    final AppDb db = seed.db;
    addTearDown(db.close);
    final Map<String, Object?> manifest = await _manifestOf(db);
    manifest['version'] = BackupService.backupVersion + 1;

    await expectLater(
      BackupService(db).mergeImport(_zipOf(manifest)),
      throwsA(isA<FormatException>()),
    );
    expect(await db.select(db.students).get(), hasLength(2));
  });

  test('نسخة v2 بلا حصص: زرع افتراضي وإسناد كل سطر إلى الحصة الأولى', () async {
    final (db: AppDb src, classId: int classId, kids: List<Student> kids) =
        await _seed();
    addTearDown(src.close);
    final List<LessonWindow> lessons = await src.lessonWindows();
    // سطران في حصتين مختلفتين + جلسة لكل حصة + إجازة بنطاق.
    await src.upsertAttendance(
      yearId: 1,
      classId: classId,
      studentId: kids[0].id,
      date: '2026-09-10',
      lessonId: lessons[0].id,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
      arrivalTime: '08:05',
    );
    await src.upsertAttendance(
      yearId: 1,
      classId: classId,
      studentId: kids[0].id,
      date: '2026-09-12',
      lessonId: lessons[2].id,
      status: AttendanceStatus.absent,
      source: AttendanceSource.manual,
    );
    await src.openLessonSession(
      yearId: 1,
      classId: classId,
      date: '2026-09-10',
      lessonId: lessons[0].id,
    );
    await src.into(src.leaves).insert(
          LeavesCompanion.insert(
            yearId: 1,
            studentId: kids[0].id,
            start: '2026-09-11',
            end: '2026-09-11',
            fromSlot: const Value(3),
            toSlot: const Value(4),
            type: 0,
            createdAt: '2026-09-10T08:00:00',
          ),
        );

    // بيان بصيغة 2: بلا `lessons`، وبلا أعمدة أُضيفت لاحقاً.
    final Map<String, Object?> manifest = await _manifestOf(src);
    manifest['version'] = 2;
    manifest.remove('lessons');
    for (final Map<String, Object?> r in _rows(manifest['sessions'])) {
      _drop(r, 'lesson_id');
    }
    for (final Map<String, Object?> r in _rows(manifest['attendance'])) {
      _drop(r, 'lesson_id');
      _drop(r, 'arrival_time');
    }
    for (final Map<String, Object?> r in _rows(manifest['leaves'])) {
      _drop(r, 'from_slot');
      _drop(r, 'to_slot');
    }

    final AppDb dst = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(dst.close);
    await BackupService(dst).restoreFull(_zipOf(manifest));

    final List<Lesson> restoredLessons = await dst.allLessons();
    expect(
      restoredLessons.length,
      LessonSchedule.defaultCount,
      reason: 'نسخة بلا حصص تُزرع بالجدول الافتراضي',
    );
    final int firstId = restoredLessons.first.id;

    final List<AttendanceRow> rows = await dst.select(dst.attendanceRows).get();
    expect(rows, hasLength(2), reason: 'كل سطر قديم محفوظ');
    expect(
      rows.every((AttendanceRow r) => r.lessonId == firstId),
      isTrue,
      reason: 'كل سطر قديم على الحصة الأولى',
    );
    expect(
      rows.firstWhere((AttendanceRow r) => r.status == AttendanceStatus.present)
          .arrivalTime,
      isNull,
      reason: 'v2 بلا وقت وصول: يبقى فارغاً لا يُختلق',
    );

    final List<Session> sessions = await dst.select(dst.sessions).get();
    expect(sessions, hasLength(1));
    expect(sessions.single.lessonId, firstId);

    final Leave leave = await dst.select(dst.leaves).getSingle();
    expect(leave.fromSlot, isNull, reason: 'إجازة قديمة = كل الحصص');
    expect(leave.toSlot, isNull);
  });

  test('نسخة v3: الحصص والإجازات والحضور تعود كما هي', () async {
    final (db: AppDb src, classId: int classId, kids: List<Student> kids) =
        await _seed();
    addTearDown(src.close);
    final List<LessonWindow> lessons = await src.lessonWindows();
    await src.saveLessons(<LessonWindow>[
      for (final LessonWindow l in lessons)
        LessonWindow(
          id: l.id,
          slot: l.slot,
          name: 'حصة ${l.slot}',
          start: l.start,
          end: l.end,
        ),
    ]);
    await src.upsertAttendance(
      yearId: 1,
      classId: classId,
      studentId: kids[0].id,
      date: '2026-09-10',
      lessonId: lessons[0].id,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
      arrivalTime: '08:02',
    );
    await src.upsertAttendance(
      yearId: 1,
      classId: classId,
      studentId: kids[0].id,
      date: '2026-09-10',
      lessonId: lessons[2].id,
      status: AttendanceStatus.late,
      source: AttendanceSource.scan,
      arrivalTime: '10:00',
    );
    await src.into(src.leaves).insert(
          LeavesCompanion.insert(
            yearId: 1,
            studentId: kids[1].id,
            start: '2026-09-12',
            end: '2026-09-13',
            fromSlot: const Value(2),
            toSlot: const Value(5),
            type: 1,
            createdAt: '2026-09-11T08:00:00',
          ),
        );

    final Uint8List zip = await BackupService(src).exportBytes();
    final AppDb dst = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(dst.close);
    await BackupService(dst).restoreFull(zip);

    final List<Lesson> restored = (await dst.allLessons())
        .toList()
      ..sort((Lesson a, Lesson b) => a.id.compareTo(b.id));
    expect(
      <int>[for (final Lesson l in restored) l.id],
      <int>[for (final LessonWindow l in lessons) l.id],
    );
    expect(
      <String>[for (final Lesson l in restored) l.name],
      <String>[for (int i = 1; i <= lessons.length; i++) 'حصة $i'],
    );

    final List<AttendanceRow> rows = await dst.select(dst.attendanceRows).get();
    expect(rows, hasLength(2));
    expect(
      <int>{for (final AttendanceRow r in rows) r.lessonId},
      <int>{lessons[0].id, lessons[2].id},
      reason: 'كل سجل يبقى في حصته',
    );

    final Leave leave = await dst.select(dst.leaves).getSingle();
    expect(leave.fromSlot, 2);
    expect(leave.toSlot, 5);
    expect(leave.type, 1);

    // الرابط المرجعي سليم بعد الاستعادة: الحصص والأصفة والطلاب والسجلات.
    expect(
      (await dst.customSelect('PRAGMA foreign_keys').getSingle())
          .data
          .values
          .first,
      1,
      reason: 'المفاتيح الأجنبية مفعّلة على اتصال القاعدة المستعادة',
    );
    expect(
      await dst.customSelect('PRAGMA foreign_key_check').get(),
      isEmpty,
      reason: 'لا صف يتيم بعد الاستعادة الكاملة',
    );
  });

  test('الدمج: حصتان في اليوم نفسه تُدمان، ولا تُدمج الحصة نفسها مرتين', () async {
    final (db: AppDb src, classId: int classId, kids: List<Student> kids) =
        await _seed();
    addTearDown(src.close);
    final List<LessonWindow> lessons = await src.lessonWindows();
    await src.upsertAttendance(
      yearId: 1,
      classId: classId,
      studentId: kids[0].id,
      date: '2026-09-10',
      lessonId: lessons[0].id,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
    );
    await src.upsertAttendance(
      yearId: 1,
      classId: classId,
      studentId: kids[0].id,
      date: '2026-09-12',
      lessonId: lessons[2].id,
      status: AttendanceStatus.absent,
      source: AttendanceSource.manual,
    );
    final Map<String, Object?> manifest = await _manifestOf(src);

    final (db: AppDb dst, classId: int dstClass, kids: List<Student> dstKids) =
        await _seed();
    addTearDown(dst.close);
    expect(dstClass, classId, reason: 'نفس المعرّفات لأن البناء واحد');

    final Map<String, int> first = await BackupService(dst).mergeImport(
      _zipOf(manifest),
    );
    expect(first['attendance'], 2, reason: 'حصتان مختلفتان تُدمان كلتاهما');
    expect(first['sessions'], 0);
    final List<AttendanceRow> after = await dst.select(dst.attendanceRows).get();
    expect(after, hasLength(2));
    expect(
      <int>{for (final AttendanceRow r in after) r.lessonId},
      <int>{lessons[0].id, lessons[2].id},
    );
    expect(dstKids, isNotEmpty);

    // الدمج الثاني: لا سطر جديد (نفس المفتاح student+date+lesson).
    final Map<String, int> second = await BackupService(dst).mergeImport(
      _zipOf(manifest),
    );
    expect(second['attendance'], 0);
    expect(
      await dst.select(dst.attendanceRows).get(),
      hasLength(2),
      reason: 'لا تضاعف عند تكرار الدمج',
    );
  });

  test('الدمج: حصة غير موجودة تُسقَط على الأولى، وطالب غير موجود يُتخطّى',
      () async {
    final (db: AppDb src, classId: int classId, kids: List<Student> kids) =
        await _seed();
    addTearDown(src.close);
    final List<LessonWindow> lessons = await src.lessonWindows();
    // سطر مرجعي حقيقي نحتفظ بشكله ثم نحرّف معرّفاته.
    await src.upsertAttendance(
      yearId: 1,
      classId: classId,
      studentId: kids[0].id,
      date: '2026-09-16',
      lessonId: lessons[3].id,
      status: AttendanceStatus.late,
      source: AttendanceSource.scan,
      arrivalTime: '11:00',
    );
    final Map<String, Object?> manifest = await _manifestOf(src);
    final Map<String, Object?> shape =
        (await src.select(src.attendanceRows).get()).first.toJson();

    // سطران يدويان: أحدهما لحصة غير موجودة (٩٩٩) والآخر لطالب غير موجود.
    final Map<String, Object?> orphanLesson = _with(shape, <String, Object?>{
      'id': 9001,
      'lesson_id': 999,
      'date': '2026-09-14',
    });
    final Map<String, Object?> orphanStudent =
        _with(orphanLesson, <String, Object?>{
      'id': 9002,
      'lesson_id': lessons[1].id,
      'student_id': 999,
      'date': '2026-09-15',
    });
    manifest['attendance'] = <Map<String, Object?>>[
      orphanLesson,
      orphanStudent,
    ];
    manifest['sessions'] = <Map<String, Object?>>[];
    manifest['scanEvents'] = <Map<String, Object?>>[];

    final ({AppDb db, int classId, List<Student> kids}) target = await _seed();
    final AppDb dst = target.db;
    addTearDown(dst.close);
    final Map<String, int> counts = await BackupService(dst).mergeImport(
      _zipOf(manifest),
    );
    final List<AttendanceRow> rows = await dst.select(dst.attendanceRows).get();
    final String seen = <String>[
      for (final AttendanceRow r in rows)
        'student=${r.studentId} lesson=${r.lessonId} date=${r.date}',
    ].join(' | ');
    expect(
      counts['attendance'],
      1,
      reason: 'السطر الصالح وحده يُدرج — counts=$counts rows=[$seen]',
    );
    expect(
      counts['skipped'],
      1,
      reason: 'سطر الطالب المفقود يُتخطّى ويُعدّ — counts=$counts',
    );
    expect(rows, hasLength(1), reason: 'الصفوف بعد الدمج: [$seen]');
    expect(
      rows.single.lessonId,
      (await dst.firstLesson()).id,
      reason: 'حصة غير موجودة ⇒ الحصة الأولى',
    );
  });

  test('الدمج: أحداث المسح لا تتضاعف عند تكرار الدمج', () async {
    final (db: AppDb src, classId: int classId, kids: List<Student> kids) =
        await _seed();
    addTearDown(src.close);
    final Session session = await src.openLessonSession(
      yearId: 1,
      classId: classId,
      date: '2026-09-16',
      lessonId: (await src.firstLesson()).id,
    );
    await src.into(src.scanEvents).insert(
          ScanEventsCompanion(
            sessionId: Value(session.id),
            code: const Value('ABC123'),
            studentId: Value(kids[0].id),
            result: const Value(ScanResult.ok),
            at: const Value('2026-09-16T08:01:00'),
          ),
        );
    final Map<String, Object?> manifest = await _manifestOf(src);

    final ({AppDb db, int classId, List<Student> kids}) target = await _seed();
    final AppDb dst = target.db;
    addTearDown(dst.close);
    final Map<String, int> first = await BackupService(dst).mergeImport(
      _zipOf(manifest),
    );
    expect(first['scanEvents'], 1);
    final Map<String, int> second = await BackupService(dst).mergeImport(
      _zipOf(manifest),
    );
    expect(second['scanEvents'], 0);
    expect(await dst.select(dst.scanEvents).get(), hasLength(1));
  });
}
