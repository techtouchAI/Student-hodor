/// قاعدة البيانات المحلية (SQLite عبر Drift): المخطط الكامل + عمليات الذرة.
///
/// مبادئ:
/// - كل تاريخ يُخزّن كمفتاح نصي ISO (yyyy-MM-dd) قابل للفهرسة والمقارنة.
/// - قيود فريدة تمنع التكرار المنطقي (طالب/تاريخ، جلسة/صف/تاريخ، رمز باج).
/// - إقفال اليوم عملية ذرّية (transaction): الغياب يُشتق ممن لم يُمسح.
/// - التسلسل (`seq`) فريد على مستوى **السنة الدراسية كلها** (لا الصف) لأنه يدخل
///   في رمز الباج الفريد؛ مصدره الوحيد [AppDb.nextSeqForYear] داخل معاملة.
library;

import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/badge_code.dart';
import '../core/nav.dart';

part 'db.g.dart';

/// حالات الحضور. تُخزّن كأرقام ثابتة لا تتغير بين الإصدارات.
class AttendanceStatus {
  const AttendanceStatus._();
  static const int present = 0;
  static const int absent = 1;
  static const int leave = 2;
  static const int late = 3;
}

/// مصدر تسجيل الحضور.
class AttendanceSource {
  const AttendanceSource._();
  static const int scan = 0;
  static const int manual = 1;
  static const int autoClose = 2;
}

/// نتائج قراءة الباركود.
class ScanResult {
  const ScanResult._();
  static const int ok = 0;
  static const int duplicate = 1;
  static const int unknownCode = 2;
  static const int revoked = 3;
  static const int wrongClass = 4;
  static const int wrongYear = 5;
  static const int sessionClosed = 6;
  static const int late = 7;
}

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

class AcademicYears extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 80)();
  TextColumn get start => text()();
  TextColumn get end => text()();
  BoolColumn get active => boolean().withDefault(const Constant(false))();
  BoolColumn get closed => boolean().withDefault(const Constant(false))();
  TextColumn get closedAt => text().nullable()();
}

@DataClassName('SchoolClass')
class SchoolClasses extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get yearId =>
      integer().references(AcademicYears, #id, onDelete: KeyAction.cascade)();
  TextColumn get grade => text().withLength(min: 1, max: 60)();
  TextColumn get section => text().withLength(min: 1, max: 30)();
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
        <Column<Object>>{yearId, grade, section},
      ];
}

class Students extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get yearId =>
      integer().references(AcademicYears, #id, onDelete: KeyAction.cascade)();
  IntColumn get classId =>
      integer().references(SchoolClasses, #id, onDelete: KeyAction.cascade)();
  TextColumn get fullName => text().withLength(min: 1, max: 120)();
  /// مفتاح هوية الطالب عبر السنوات (للتقارير متعددة السنوات والترقية).
  TextColumn get personKey => text()();
  IntColumn get seq => integer()();
  TextColumn get photoPath => text().nullable()();
  TextColumn get createdAt => text()();
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
        <Column<Object>>{yearId, seq},
      ];
}

class Badges extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get studentId =>
      integer().references(Students, #id, onDelete: KeyAction.cascade)();
  TextColumn get code => text().unique()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  /// 0 = فعال، 1 = مبطل (بدل فاقد).
  IntColumn get status => integer().withDefault(const Constant(0))();
  TextColumn get issuedAt => text()();
}

class Sessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get yearId =>
      integer().references(AcademicYears, #id, onDelete: KeyAction.cascade)();
  IntColumn get classId =>
      integer().references(SchoolClasses, #id, onDelete: KeyAction.cascade)();
  TextColumn get date => text()();
  TextColumn get openedAt => text()();
  TextColumn get closedAt => text().nullable()();
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
        <Column<Object>>{classId, date},
      ];
}

class AttendanceRows extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get yearId =>
      integer().references(AcademicYears, #id, onDelete: KeyAction.cascade)();
  IntColumn get classId =>
      integer().references(SchoolClasses, #id, onDelete: KeyAction.cascade)();
  IntColumn get studentId =>
      integer().references(Students, #id, onDelete: KeyAction.cascade)();
  TextColumn get date => text()();
  IntColumn get status => integer()();
  IntColumn get source => integer()();
  IntColumn get sessionId => integer().nullable()();
  TextColumn get note => text().nullable()();
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
        <Column<Object>>{studentId, date},
      ];
}

class ScanEvents extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId => integer().nullable()();
  TextColumn get code => text()();
  IntColumn get studentId => integer().nullable()();
  IntColumn get result => integer()();
  TextColumn get at => text()();
}

class Leaves extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get yearId =>
      integer().references(AcademicYears, #id, onDelete: KeyAction.cascade)();
  IntColumn get studentId =>
      integer().references(Students, #id, onDelete: KeyAction.cascade)();
  TextColumn get start => text()();
  TextColumn get end => text()();
  /// 0 = مرضية، 1 = عرضية، 2 = طارئة.
  IntColumn get type => integer()();
  TextColumn get reason => text().withDefault(const Constant(''))();
  TextColumn get createdAt => text()();
}

class Holidays extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get date => text().unique()();
  TextColumn get title => text()();
}

class AuditLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get at => text()();
  TextColumn get actor => text()();
  TextColumn get action => text()();
  TextColumn get details => text().withDefault(const Constant(''))();
}

@DriftDatabase(
  tables: <Type>[
    Settings,
    AcademicYears,
    SchoolClasses,
    Students,
    Badges,
    Sessions,
    AttendanceRows,
    ScanEvents,
    Leaves,
    Holidays,
    AuditLogs,
  ],
)
class AppDb extends _$AppDb {
  AppDb() : super(_openConnection());

  AppDb.forTesting(super.e);

  /// الإصدار 2: فهارس على الأعمدة الساخنة (لا تغيير جداول ⇒ لا فقد بيانات).
  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
          await _ensureIndexes();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // هجرات مرقّمة تُضاف هنا مع كل تغيير مخطط.
          if (from < 2) {
            await _ensureIndexes();
          }
        },
      );

  Future<void> _ensureIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_attendance_date ON attendance_rows (date)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_attendance_class_date '
      'ON attendance_rows (class_id, date)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_attendance_student '
      'ON attendance_rows (student_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_leaves_student ON leaves (student_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_scan_session ON scan_events (session_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_students_year_class '
      'ON students (year_id, class_id)',
    );
  }

  // ---------- إعدادات ----------

  /// قيم افتراضية تُدمج عند القراءة فلا تعتمد شاشة على وجود مفتاح مسبق.
  static const Map<String, String> settingDefaults = <String, String>{
    'work_weekdays': '7,1,2,3,4',
    'show_hijri': '1',
    'alert_threshold_1': '10',
    'alert_threshold_2': '15',
    'day_start': '08:00',
    'late_after_minutes': '15',
  };

  Future<String?> setting(String key) async =>
      (await (select(settings)..where((s) => s.key.equals(key))).getSingleOrNull())
          ?.value;

  Future<void> setSetting(String key, String value) async =>
      into(settings).insertOnConflictUpdate(
        Setting(key: key, value: value),
      );

  Future<Map<String, String>> allSettings() async => <String, String>{
        for (final Setting s in await select(settings).get()) s.key: s.value,
      };

  /// الإعدادات المخزّنة فوق القيم الافتراضية — ما تستخدمه الشاشات دائماً.
  Future<Map<String, String>> effectiveSettings() async =>
      <String, String>{...settingDefaults, ...await allSettings()};

  // ---------- سنوات ----------

  Stream<AcademicYear?> watchActiveYear() =>
      (select(academicYears)
            ..where((y) => y.active.equals(true) & y.closed.equals(false)))
          .watchSingleOrNull();

  Future<AcademicYear?> activeYear() async =>
      (select(academicYears)..where((y) => y.active.equals(true) & y.closed.equals(false)))
          .getSingleOrNull();

  Future<AcademicYear?> yearById(int id) =>
      (select(academicYears)..where((y) => y.id.equals(id))).getSingleOrNull();

  // ---------- طلاب وصفوف ----------

  Future<Student?> studentById(int id) =>
      (select(students)..where((s) => s.id.equals(id))).getSingleOrNull();

  /// عنوان صف للعرض («السادس ـ أ») أو null إن لم يوجد.
  Future<String?> classTitle(int classId) async {
    final SchoolClass? c = await (select(schoolClasses)
          ..where((x) => x.id.equals(classId)))
        .getSingleOrNull();
    return c == null ? null : '${c.grade} ـ ${c.section}';
  }

  /// حلّ مرجع صف لشاشات (طلاب/بادجات/مسح/كشف اليوم).
  ///
  /// هذه هي الحماية الجوهرية من «الشاشة البيضاء/الفارغة»: لا تعتمد الشاشة على
  /// معاملة رابط سليمة، بل:
  /// 1. إن جاء معرّف صالح ⇒ يُعتمد ويُستكمل عنوانه من القاعدة إن كان ناقصاً.
  /// 2. إن جاء `0` أو معرّف محذوف ⇒ يُعتمد أول صف في السنة الفعّالة (أو يُعرض
  ///    منتقي صفوف إن وُجد أكثر من صف) بدل شاشة فارغة بلا تفسير.
  ///
  /// يعيد `(عدد صفوف السنة الفعّالة، المرجع)`؛ المرجع `null` يعني «اسأل المستخدم».
  Future<(int, ClassRef?)> resolveClassRef(ClassRef requested) async {
    final AcademicYear? year = await activeYear();
    if (year == null) {
      return (0, null);
    }
    final List<SchoolClass> classes = await (select(schoolClasses)
          ..where((c) => c.yearId.equals(year.id))
          ..orderBy(<OrderClauseGenerator<SchoolClasses>>[
            (SchoolClasses c) => OrderingTerm.asc(c.grade),
            (SchoolClasses c) => OrderingTerm.asc(c.section),
          ]))
        .get();
    SchoolClass? match;
    for (final SchoolClass c in classes) {
      if (c.id == requested.id) {
        match = c;
        break;
      }
    }
    if (match == null && requested.id > 0 && classes.length == 1) {
      // رابط قديم/صف محذوف: صف وحيد في السنة ⇒ لا داعي لسؤال المستخدم.
      match = classes.single;
    }
    if (match == null && requested.id <= 0 && classes.length == 1) {
      match = classes.single;
    }
    if (match == null) {
      return (classes.length, null);
    }
    final String title = requested.title.trim().isNotEmpty
        ? requested.title.trim()
        : '${match.grade} ـ ${match.section}';
    return (classes.length, ClassRef(id: match.id, title: title));
  }

  /// التسلسل الفريد التالي على مستوى **السنة** (لا الصف) — يدخل في رمز الباج
  /// وفي القيد الفريد (yearId, seq)، لذا مصدره هنا وحده وداخل معاملة.
  Future<int> nextSeqForYear(int yearId) async {
    final List<Student> all =
        await (select(students)..where((s) => s.yearId.equals(yearId))).get();
    return all.fold<int>(0, (int m, Student t) => t.seq > m ? t.seq : m) + 1;
  }

  /// هوية مستقرة للطالب عبر السنوات: مولّدة مرة واحدة ولا تعتمد على الاسم.
  static String makePersonKey() {
    final int t = DateTime.now().microsecondsSinceEpoch;
    final int r = _rng.nextInt(1 << 30);
    return 'PK-${t.toRadixString(36)}-${r.toRadixString(36).toUpperCase()}';
  }

  static final Random _rng = Random();

  /// إضافة طالب + باجه الأول بعملية ذرّية واحدة (تسلسل سنة فريد + رمز فريد).
  Future<int> addStudent({
    required int yearId,
    required int classId,
    required String fullName,
    String? photoPath,
  }) async =>
      transaction<int>(() async {
        final int seq = await nextSeqForYear(yearId);
        final int id = await into(students).insert(
          StudentsCompanion(
            yearId: Value(yearId),
            classId: Value(classId),
            fullName: Value(fullName),
            personKey: Value(makePersonKey()),
            seq: Value(seq),
            photoPath: Value(photoPath),
            createdAt: Value(DateTime.now().toIso8601String()),
          ),
        );
        final String school = await setting('school_name') ?? '';
        final AcademicYear? y = await yearById(yearId);
        final int yearShort =
            y == null ? 0 : (int.tryParse(y.start.substring(2, 4)) ?? 0);
        await into(badges).insert(
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
        await logAudit('student_add', fullName);
        return id;
      });

  /// حذف طالب وكل ما يرتبط به (باجات/حضور/إجازات/أحداث مسح) بمعاملة واحدة.
  Future<void> deleteStudent(int id) async => transaction<void>(() async {
        await (delete(scanEvents)..where((e) => e.studentId.equals(id))).go();
        await (delete(attendanceRows)..where((a) => a.studentId.equals(id))).go();
        await (delete(leaves)..where((l) => l.studentId.equals(id))).go();
        await (delete(badges)..where((b) => b.studentId.equals(id))).go();
        await (delete(students)..where((s) => s.id.equals(id))).go();
        await logAudit('student_delete', 'id=$id');
      });

  Future<int> countStudentsInClass(int classId) async {
    final List<Student> kids =
        await (select(students)..where((s) => s.classId.equals(classId))).get();
    return kids.length;
  }

  /// حذف صف فارغ فقط (تفرضه الشاشة) مع جلساته.
  Future<void> deleteClass(int classId) async => transaction<void>(() async {
        await (delete(sessions)..where((s) => s.classId.equals(classId))).go();
        await (delete(schoolClasses)..where((c) => c.id.equals(classId))).go();
        await logAudit('class_delete', 'id=$classId');
      });

  // ---------- بادجات ----------

  Future<Badge?> activeBadgeOf(int studentId) =>
      (select(badges)
            ..where((b) => b.studentId.equals(studentId) & b.status.equals(0)))
          .getSingleOrNull();

  /// بدل فاقد: إبطال الباج الفعال وإصدار باجر برمز مختلف (نسخة أعلى).
  Future<Badge?> reissueBadge(int studentId) async =>
      transaction<Badge?>(() async {
        final Student? st = await studentById(studentId);
        if (st == null) {
          return null;
        }
        final Badge? old = await activeBadgeOf(studentId);
        final int version = (old?.version ?? 0) + 1;
        if (old != null) {
          await (update(badges)..where((b) => b.id.equals(old.id))).write(
            const BadgesCompanion(status: Value(1)),
          );
        }
        final String school = await setting('school_name') ?? '';
        final AcademicYear? y = await yearById(st.yearId);
        final int yearShort =
            y == null ? 0 : (int.tryParse(y.start.substring(2, 4)) ?? 0);
        final Badge row = await into(badges).insertReturning(
          BadgesCompanion(
            studentId: Value(studentId),
            code: Value(
              BadgeCode.make(
                schoolName: school,
                sequence: st.seq,
                yearShort: yearShort,
                version: version,
              ),
            ),
            version: Value(version),
            issuedAt: Value(DateTime.now().toIso8601String()),
          ),
        );
        await logAudit('badge_reissue', 'student=$studentId v=$version');
        return row;
      });

  // ---------- جلسات وحضور ----------

  Future<Session?> sessionOf(int classId, String date) =>
      (select(sessions)
            ..where((s) => s.classId.equals(classId) & s.date.equals(date)))
          .getSingleOrNull();

  Stream<Session?> watchSession(int classId, String date) =>
      (select(sessions)
            ..where((s) => s.classId.equals(classId) & s.date.equals(date)))
          .watchSingleOrNull();

  Future<List<AttendanceRow>> attendanceForClassDate(
    int classId,
    String date,
  ) async =>
      (select(attendanceRows)
            ..where((a) => a.classId.equals(classId) & a.date.equals(date)))
          .get();

  /// عدد الطلاب المسجَّلين (حاضر/متأخر/إجازة) ليوم صف — لعرض «المتبقي».
  Future<int> recordedCount(int classId, String date) async {
    final List<AttendanceRow> rows = await attendanceForClassDate(classId, date);
    return rows
        .where(
          (AttendanceRow r) =>
              r.status == AttendanceStatus.present ||
              r.status == AttendanceStatus.late ||
              r.status == AttendanceStatus.leave,
        )
        .length;
  }

  Future<AttendanceRow?> attendanceOf(int studentId, String date) async =>
      (select(attendanceRows)
            ..where((a) => a.studentId.equals(studentId) & a.date.equals(date)))
          .getSingleOrNull();

  /// تسجيل/تحديث حالة حضور لطالب في تاريخ (idempotent).
  ///
  /// ملاحظة: `insertOnConflictUpdate` يستهدف القيد الفريد الأساسي (id) فقط،
  /// لذا يُنفَّذ الإدراج أو التحديث صراحةً وفق القيد الفريد (studentId, date).
  Future<void> upsertAttendance({
    required int yearId,
    required int classId,
    required int studentId,
    required String date,
    required int status,
    required int source,
    int? sessionId,
    String? note,
  }) async {
    final AttendanceRow? existing = await attendanceOf(studentId, date);
    if (existing == null) {
      await into(attendanceRows).insert(
        AttendanceRowsCompanion(
          yearId: Value(yearId),
          classId: Value(classId),
          studentId: Value(studentId),
          date: Value(date),
          status: Value(status),
          source: Value(source),
          sessionId: Value(sessionId),
          note: Value(note),
        ),
      );
      return;
    }
    await (update(attendanceRows)..where((a) => a.id.equals(existing.id))).write(
      AttendanceRowsCompanion(
        yearId: Value(yearId),
        classId: Value(classId),
        status: Value(status),
        source: Value(source),
        sessionId: Value(sessionId),
        note: Value(note),
      ),
    );
  }

  /// هل يغطي الطالبَ إجازةٌ في هذا التاريخ؟ (فلترة SQL لا تحميل الذاكرة).
  Future<bool> isOnLeave(int studentId, String date) async =>
      (await (select(leaves)
                ..where(
                  (l) =>
                      l.studentId.equals(studentId) &
                      l.start.isSmallerOrEqualValue(date) &
                      l.end.isBiggerOrEqualValue(date),
                ))
              .get())
          .isNotEmpty;

  /// وسم التحويل بالمزامنة: يميّز الغياب الذي ألغته إجازة عن إجازة
  /// سجّلها بشر يدوياً — الأول يعود غياباً عند حذف الإجازة والثانية تبقى.
  static const String leaveSyncNote = 'leave-sync';

  /// مزامنة إجازة مع سجلات الحضور داخل نطاقها:
  /// إضافة ⇒ أي غياب (تلقائي أو يدوي) يصبح إجازة مع بقاء مصدره؛
  /// حذف ⇒ ما حُوّل بالمزامنة أو وُلّد تلقائياً يعود غياباً إن لم تغطّه
  /// إجازة أخرى. الحضور والتأخر لا يُمسّان أبداً (واقعة حضور ثابتة).
  Future<int> syncLeaveToAttendance({
    required int studentId,
    required String start,
    required String end,
    required bool added,
  }) async =>
      transaction<int>(() async {
        final Student? st = await studentById(studentId);
        if (st == null) {
          return 0;
        }
        final List<AttendanceRow> rows = await (select(attendanceRows)
              ..where(
                (a) =>
                    a.studentId.equals(studentId) &
                    a.date.isBiggerOrEqualValue(start) &
                    a.date.isSmallerOrEqualValue(end),
              ))
            .get();
        int changed = 0;
        for (final AttendanceRow r in rows) {
          if (added && r.status == AttendanceStatus.absent) {
            await upsertAttendance(
              yearId: r.yearId,
              classId: r.classId,
              studentId: r.studentId,
              date: r.date,
              status: AttendanceStatus.leave,
              source: r.source,
              sessionId: r.sessionId,
              note: leaveSyncNote,
            );
            changed++;
          } else if (!added &&
              r.status == AttendanceStatus.leave &&
              (r.note == leaveSyncNote ||
                  r.source == AttendanceSource.autoClose)) {
            final bool stillCovered = await isOnLeave(studentId, r.date);
            if (!stillCovered) {
              await upsertAttendance(
                yearId: r.yearId,
                classId: r.classId,
                studentId: r.studentId,
                date: r.date,
                status: AttendanceStatus.absent,
                source: r.source,
                sessionId: r.sessionId,
                note: null,
              );
              changed++;
            }
          }
        }
        return changed;
      });

  /// حذف تسجيل حضور ليوم (تصحيح يدوي من شبكة ملف الطالب).
  Future<void> deleteAttendance(int studentId, String date) async =>
      (delete(attendanceRows)
            ..where(
              (a) => a.studentId.equals(studentId) & a.date.equals(date),
            ))
          .go();

  /// إقفال جلسة اليوم: كل طالب بلا تسجيل وبلا إجازة => غائب. عملية ذرّية.
  /// يعيد عدد سجلات الغياب المولّدة.
  Future<int> closeSession(int sessionId) async => transaction<int>(() async {
        final Session? session = await (select(sessions)
              ..where((s) => s.id.equals(sessionId)))
            .getSingleOrNull();
        if (session == null || session.closedAt != null) {
          return 0;
        }
        final List<Student> roster = await (select(students)
              ..where((s) => s.classId.equals(session.classId)))
            .get();
        int generated = 0;
        for (final Student st in roster) {
          final AttendanceRow? existing =
              await attendanceOf(st.id, session.date);
          if (existing != null) {
            continue;
          }
          if (await isOnLeave(st.id, session.date)) {
            await upsertAttendance(
              yearId: session.yearId,
              classId: session.classId,
              studentId: st.id,
              date: session.date,
              status: AttendanceStatus.leave,
              source: AttendanceSource.autoClose,
              sessionId: sessionId,
            );
          } else {
            await upsertAttendance(
              yearId: session.yearId,
              classId: session.classId,
              studentId: st.id,
              date: session.date,
              status: AttendanceStatus.absent,
              source: AttendanceSource.autoClose,
              sessionId: sessionId,
            );
          }
          generated++;
        }
        await (update(sessions)..where((s) => s.id.equals(sessionId)))
            .write(SessionsCompanion(closedAt: Value(_now())));
        await logAudit('close_session', 'session=$sessionId generated=$generated');
        return generated;
      });

  /// إعادة فتح جلسة مقفلة: يحذف السجلات المولّدة تلقائياً ويصفّر تاريخ الإقفال.
  Future<void> reopenSession(int sessionId) async => transaction<void>(() async {
        await (delete(attendanceRows)
              ..where(
                (a) =>
                    a.sessionId.equals(sessionId) &
                    a.source.equals(AttendanceSource.autoClose),
              ))
            .go();
        await (update(sessions)..where((s) => s.id.equals(sessionId)))
            .write(const SessionsCompanion(closedAt: Value(null)));
        await logAudit('reopen_session', 'session=$sessionId');
      });

  // ---------- تدقيق ----------

  Future<void> logAudit(String action, [String details = '']) async =>
      into(auditLogs).insert(
        AuditLogsCompanion(
          at: Value(_now()),
          actor: const Value('local'),
          action: Value(action),
          details: Value(details),
        ),
      );

  static String _now() => DateTime.now().toIso8601String();
}

LazyDatabase _openConnection() => LazyDatabase(() async {
      final Directory dir = await getApplicationDocumentsDirectory();
      return NativeDatabase.createInBackground(
        File(p.join(dir.path, 'student_hodor.db')),
      );
    });
