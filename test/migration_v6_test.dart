import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/lesson.dart';
import 'package:student_hodor/data/db.dart';

/// اختبار الترقية الحقيقية: قاعدة **إصدار 5** على القرص (يوم كامل) تُفتح
/// بتطبيق الإصدار 6 (حصص) بلا فقدان سطر واحد.
///
/// الطريقة: تُنشأ قاعدة 6 بمخطط Drift نفسه (فتكون بقية الجداول مطابقة تماماً)،
/// ثم يُعاد تشكيل `sessions` و`attendance_rows` و`leaves` و`lessons` يدوياً إلى
/// مخطط 5 وتُضبط `user_version = 5`، فتُفتح من جديد فتعمل الهجرة فعلياً — لا
/// محاكاة ولا التفاف على المنطق.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hodor_mig_');
  });

  tearDown(() async {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  test('ترقية 5⇒6 تُسند كل سطر قديم إلى الحصة الأولى وتُبقي البيانات', () async {
    final File file = File('${dir.path}/school_v5.sqlite');

    // ---------- (1) قاعدة إصدار 5 ----------
    final AppDb v5 = AppDb.forTesting(NativeDatabase(file));
    final _Base base = await _seedBase(v5);
    await _shapeAsVersion5(v5);
    // معطيات «يوم كامل»: جلسة واحدة للصف في اليوم، وسطر لكل طالب.
    await v5.customStatement(
      'INSERT INTO sessions (id, year_id, class_id, date, opened_at, '
      'closed_at) VALUES (1, ${base.yearId}, ${base.classId}, '
      "'2026-09-01', '2026-09-01T08:00:00', NULL)",
    );
    await v5.customStatement(
      'INSERT INTO attendance_rows (id, year_id, class_id, student_id, date, '
      'status, source, session_id, note, arrival_time) VALUES '
      '(1, ${base.yearId}, ${base.classId}, ${base.firstStudentId}, '
      "'2026-09-01', 0, 0, 1, NULL, '08:05'), "
      '(2, ${base.yearId}, ${base.classId}, ${base.secondStudentId}, '
      "'2026-09-01', 1, 2, 1, NULL, NULL)",
    );
    // حدث مسح مرتبط بالجلسة القديمة: يجب أن يبقى مربوطاً بعد إعادة البناء.
    await v5.into(v5.scanEvents).insert(
          ScanEventsCompanion(
            sessionId: const Value(1),
            code: const Value('SH-XXX-0001-26-K7'),
            studentId: Value(base.firstStudentId),
            result: const Value(ScanResult.ok),
            at: const Value('2026-09-01T08:04:00'),
          ),
        );
    await v5.close();

    // ---------- (2) الفتح بتطبيق الإصدار 6 ----------
    final AppDb db = AppDb.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    final List<Lesson> lessons = await db.allLessons();
    expect(
      lessons.length,
      LessonSchedule.defaults.length,
      reason: 'الهجرة تزرع الجدول الافتراضي قبل أي إسناد',
    );
    expect(lessons.first.slot, 1);
    expect(lessons.first.start, LessonSchedule.defaults.first.start);
    final int firstId = lessons.first.id;
    final int secondId = lessons[1].id;

    final List<Session> sessions = await db.select(db.sessions).get();
    expect(sessions, hasLength(1), reason: 'لا سطر قديم يُفقد');
    expect(
      sessions.single.lessonId,
      firstId,
      reason: 'اليوم القديم ⇒ الحصة الأولى',
    );
    expect(sessions.single.closedAt, isNull);

    // سلامة الروابط المرجعية بعد الهجرة: المفاتيح مفعّلة ولا صف يتيم.
    expect(
      (await db.customSelect('PRAGMA foreign_keys').getSingle())
          .data
          .values
          .first,
      1,
      reason: 'PRAGMA foreign_keys فعّال فعلاً على الاتصال بعد الهجرة',
    );
    expect(
      await db.customSelect('PRAGMA foreign_key_check').get(),
      isEmpty,
      reason: 'لا صف يتيم بعد 5⇒6',
    );

    final List<AttendanceRow> rows = await db.select(db.attendanceRows).get();
    expect(rows, hasLength(2));
    expect(rows.every((AttendanceRow r) => r.lessonId == firstId), isTrue);
    expect(
      rows.firstWhere((AttendanceRow r) => r.id == 1).arrivalTime,
      '08:05',
      reason: 'وقت الوصول القديم يبقى كما هو',
    );
    expect(
      rows.firstWhere((AttendanceRow r) => r.id == 2).status,
      AttendanceStatus.absent,
    );

    // ---------- (3) التفرّد الجديد: حصة ثانية في اليوم نفسه ----------
    await db.upsertAttendance(
      yearId: base.yearId,
      classId: base.classId,
      studentId: base.firstStudentId,
      date: '2026-09-01',
      lessonId: secondId,
      status: AttendanceStatus.present,
      source: AttendanceSource.manual,
    );
    expect(
      await db.select(db.attendanceRows).get(),
      hasLength(3),
      reason: 'التفرّد أصبح (طالب، تاريخ، حصة) لا (طالب، تاريخ)',
    );

    final Session second = await db.openLessonSession(
      yearId: base.yearId,
      classId: base.classId,
      date: '2026-09-01',
      lessonId: secondId,
    );
    expect(second.lessonId, secondId);
    expect(
      await db.select(db.sessions).get(),
      hasLength(2),
      reason: 'جلسة لكل (صف، تاريخ، حصة)',
    );

    // ---------- (4) نطاق الإجازة على جدول قديم ----------
    final int leaveId = await db.into(db.leaves).insert(
          LeavesCompanion.insert(
            yearId: base.yearId,
            studentId: base.firstStudentId,
            start: '2026-09-03',
            end: '2026-09-03',
            type: 0,
            createdAt: '2026-09-03T07:00:00',
          ),
        );
    final Leave inserted = await (db.select(db.leaves)
          ..where((Leaves l) => l.id.equals(leaveId)))
        .getSingle();
    expect(
      inserted.fromSlot,
      isNull,
      reason: 'الإجازة القديمة = كل الحصص بلا تحويل',
    );
    await (db.update(db.leaves)..where((Leaves l) => l.id.equals(leaveId)))
        .write(const LeavesCompanion(fromSlot: Value(3), toSlot: Value(5)));
    final Leave scoped = await (db.select(db.leaves)
          ..where((Leaves l) => l.id.equals(leaveId)))
        .getSingle();
    expect(scoped.fromSlot, 3);
    expect(scoped.toSlot, 5);

    // ---------- (5) الفهارس أُعيدت بعد إعادة بناء الجدولين ----------
    final List<QueryRow> indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN "
          "('idx_attendance_lesson', 'idx_attendance_date', "
          "'idx_attendance_class_date', 'idx_attendance_student')",
        )
        .get();
    expect(
      indexes.map((QueryRow r) => r.read<String>('name')).toSet(),
      <String>{
        'idx_attendance_lesson',
        'idx_attendance_date',
        'idx_attendance_class_date',
        'idx_attendance_student',
      },
    );

    // ---------- (6) التكامل المرجعي بعد إعادة البناء ----------
    final List<QueryRow> fkViolations =
        await db.customSelect('PRAGMA foreign_key_check').get();
    expect(
      fkViolations,
      isEmpty,
      reason: 'إعادة بناء الجدولين لا تترك مفتاحاً أجنبياً معلّقاً',
    );
    final List<ScanEvent> events = await db.select(db.scanEvents).get();
    expect(events, hasLength(1));
    expect(
      events.single.sessionId,
      1,
      reason: 'حدث المسح يبقى على جلسته القديمة',
    );

    // ---------- (7) الإصدار النهائي ----------
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 6);
  });

  test('قاعدة جديدة تكتب الإصدار 6 من أول فتح', () async {
    final File file = File('${dir.path}/fresh.sqlite');
    final AppDb db = AppDb.forTesting(NativeDatabase(file));
    addTearDown(db.close);

    expect(await db.lessonCount(), LessonSchedule.defaults.length);
    final QueryRow version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 6);
  });
}

class _Base {
  const _Base({
    required this.yearId,
    required this.classId,
    required this.firstStudentId,
    required this.secondStudentId,
  });

  final int yearId;
  final int classId;
  final int firstStudentId;
  final int secondStudentId;
}

/// السنة/الصف/الطلاب: جداول لم تتغير في الإصدار 6، فتُنشأ بـDrift نفسه.
Future<_Base> _seedBase(AppDb db) async {
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
  Future<int> student(String name, String key, int seq) =>
      db.into(db.students).insert(
            StudentsCompanion(
              yearId: Value(yearId),
              classId: Value(classId),
              fullName: Value(name),
              personKey: Value(key),
              seq: Value(seq),
              createdAt: const Value('2026-09-01T08:00:00'),
            ),
          );

  return _Base(
    yearId: yearId,
    classId: classId,
    firstStudentId: await student('طالب أول', 'p1', 1),
    secondStudentId: await student('طالب ثانٍ', 'p2', 2),
  );
}

/// إعادة تشكيل المخطط إلى **إصدار 5**: لا عمود `lesson_id`، والتفرّد يومي، ولا
/// جدول حصص ولا نطاق إجازة. ثم `user_version = 5` ليستدعي Drift الهجرة.
Future<void> _shapeAsVersion5(AppDb db) async {
  await db.customStatement('PRAGMA foreign_keys = OFF');

  await db.customStatement('DROP TABLE IF EXISTS sessions');
  await db.customStatement('''
    CREATE TABLE sessions (
      id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      year_id INTEGER NOT NULL REFERENCES academic_years (id) ON DELETE CASCADE,
      class_id INTEGER NOT NULL REFERENCES school_classes (id) ON DELETE CASCADE,
      date TEXT NOT NULL,
      opened_at TEXT NOT NULL,
      closed_at TEXT NULL,
      UNIQUE (class_id, date)
    )
  ''');

  await db.customStatement('DROP TABLE IF EXISTS attendance_rows');
  await db.customStatement('''
    CREATE TABLE attendance_rows (
      id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      year_id INTEGER NOT NULL REFERENCES academic_years (id) ON DELETE CASCADE,
      class_id INTEGER NOT NULL REFERENCES school_classes (id) ON DELETE CASCADE,
      student_id INTEGER NOT NULL REFERENCES students (id) ON DELETE CASCADE,
      date TEXT NOT NULL,
      status INTEGER NOT NULL,
      source INTEGER NOT NULL,
      session_id INTEGER NULL,
      note TEXT NULL,
      arrival_time TEXT NULL,
      UNIQUE (student_id, date)
    )
  ''');

  // الإجازات بلا عمودَي نطاق الحصص.
  await db.customStatement('DROP TABLE IF EXISTS leaves');
  await db.customStatement('''
    CREATE TABLE leaves (
      id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      year_id INTEGER NOT NULL REFERENCES academic_years (id) ON DELETE CASCADE,
      student_id INTEGER NOT NULL REFERENCES students (id) ON DELETE CASCADE,
      start TEXT NOT NULL,
      end TEXT NOT NULL,
      type INTEGER NOT NULL,
      reason TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )
  ''');

  await db.customStatement('DROP TABLE IF EXISTS lessons');

  await db.customStatement('PRAGMA user_version = 5');
}
