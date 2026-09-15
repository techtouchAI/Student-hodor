/// قاعدة البيانات المحلية (SQLite عبر Drift): المخطط الكامل + عمليات الذرة.
///
/// مبادئ:
/// - كل تاريخ يُخزّن كمفتاح نصي ISO (yyyy-MM-dd) قابل للفهرسة والمقارنة.
/// - قيود فريدة تمنع التكرار المنطقي (طالب/تاريخ، جلسة/صف/تاريخ، رمز باج).
/// - إقفال اليوم عملية ذرّية (transaction): الغياب يُشتق ممن لم يُمسح.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async => m.createAll(),
        onUpgrade: (Migrator m, int from, int to) async {
          // هجرات مرقّمة تُضاف هنا مع كل تغيير مخطط (إصدار 2 فصاعداً).
        },
      );

  // ---------- إعدادات ----------

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

  // ---------- سنوات ----------

  Stream<AcademicYear?> watchActiveYear() =>
      (select(academicYears)
            ..where((y) => y.active.equals(true) & y.closed.equals(false)))
          .watchSingleOrNull();

  Future<AcademicYear?> activeYear() async =>
      (select(academicYears)..where((y) => y.active.equals(true) & y.closed.equals(false)))
          .getSingleOrNull();

  // ---------- حضور ----------

  Future<AttendanceRow?> attendanceOf(int studentId, String date) async =>
      (select(attendanceRows)
            ..where((a) => a.studentId.equals(studentId) & a.date.equals(date)))
          .getSingleOrNull();

  /// تسجيل/تحديث حالة حضور لطالب في تاريخ (idempotent).
  Future<void> upsertAttendance({
    required int yearId,
    required int classId,
    required int studentId,
    required String date,
    required int status,
    required int source,
    int? sessionId,
    String? note,
  }) async =>
      into(attendanceRows).insertOnConflictUpdate(
        AttendanceRowsCompanion(
          id: const Value.absent(),
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

  Future<bool> isOnLeave(int studentId, String date) async {
    final List<Leave> covering =
        await (select(leaves)..where((l) => l.studentId.equals(studentId))).get();
    return covering.any((Leave l) =>
        l.start.compareTo(date) <= 0 && l.end.compareTo(date) >= 0);
  }

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

  /// إعادة فتح جلسة مقفلة: يحذف السجلات المولّدة تلقائياً فقط.
  Future<void> reopenSession(int sessionId) async => transaction<void>(() async {
        await (delete(attendanceRows)..where((a) =>
                a.sessionId.equals(sessionId) &
                a.source.equals(AttendanceSource.autoClose)))
            .go();
        await (update(sessions)..where((s) => s.id.equals(sessionId)))
            .write(const SessionsCompanion(closedAt: Value.absent()));
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
