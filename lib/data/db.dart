/// قاعدة البيانات المحلية (SQLite عبر Drift): المخطط الكامل + عمليات الذرة.
///
/// مبادئ:
/// - كل تاريخ يُخزّن كمفتاح نصي ISO (yyyy-MM-dd) قابل للفهرسة والمقارنة.
/// - قيود فريدة تمنع التكرار المنطقي (طالب/تاريخ/حصة، جلسة/صف/تاريخ/حصة،
///   رمز باج).
/// - الحضور **لحصة بحصة**: لكل حصة سجلها وجلستها؛ إقفال الحصة عملية ذرّية
///   (transaction): الغياب يُشتق ممن لم يُمسح في تلك الحصة وحدها.
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
import '../core/lesson.dart';
import '../core/name_import.dart';
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

/// حذف حصة لها سجلات تاريخية: مرفوض برسالة مفهومة للمستخدم.
class LessonInUseException implements Exception {
  const LessonInUseException({required this.slot, required this.records});

  /// رقم الحصة التي حاول المستخدم حذفها.
  final int slot;

  /// عدد السجلات (جلسات + حضور) المرتبطة بها.
  final int records;

  @override
  String toString() =>
      'الحصة $slot لها $records سجلاً — لا يمكن حذفها. '
      'أبقِها أو غيّر اسمها/وقتها بدل حذفها.';
}

/// تغيير ترتيب الحصص يفرض على إجازة قائمة أن تنقسم إلى نطاقين غير متصلين
/// (مثال: إجازة تغطي الحصص 3 و4 ثم صارتا 2 و5) — تُرفض العملية بدل تغيير
/// معنى الإجازة أو حذفها.
class LeaveScopeConflictException implements Exception {
  const LeaveScopeConflictException({
    required this.leaveId,
    required this.fromSlot,
    required this.toSlot,
    required this.slots,
  });

  final int leaveId;
  final int? fromSlot;
  final int? toSlot;

  /// أرقام الحصص التي كانت الإجازة تغطيها قبل التعديل.
  final List<int> slots;

  @override
  String toString() =>
      'إجازة رقم $leaveId (${fromSlot ?? 1}–${toSlot ?? 'آخر اليوم'}) كانت '
      'تغطي الحصص ${slots.join('، ')}، وبعد الترتيب الجديد تصبح حصصاً '
      'متباعدة لا يمكن التعبير عنها كنطاق واحد. أعِد ترتيب الحصص كما كانت '
      'أو عدّل الإجازة يدوياً أولاً.';
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
  /// رقم هاتف الطالب (اختياري، يُترك فارغاً إن لم يوجد).
  TextColumn get phone => text().nullable()();
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

/// جدول الحصص المدرسي: صف واحد لكل حصة في اليوم (1..N) بوقتها.
///
/// الفصل بين المعرّف ([id]) ورقم الحصة ([slot]) مقصود: السجلات التاريخية
/// تشير إلى المعرّف (فتعديل الاسم/الوقت لا يمسّها)، ونطاقات الإجازات تشير إلى
/// الرقم (فهي وصف بشري: «من الحصة الثالثة»).
class Lessons extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get slot => integer().unique()();
  TextColumn get name => text().withDefault(const Constant(''))();
  /// بداية الحصة `HH:mm` (24 ساعة) — حد التأخير يُحسب منها.
  TextColumn get start => text()();
  /// نهاية الحصة `HH:mm`.
  TextColumn get end => text()();
}

class Sessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get yearId =>
      integer().references(AcademicYears, #id, onDelete: KeyAction.cascade)();
  IntColumn get classId =>
      integer().references(SchoolClasses, #id, onDelete: KeyAction.cascade)();
  TextColumn get date => text()();
  /// الحصة التي تخصّها الجلسة. القيمة الافتراضية 1 للتوافق مع السجلات التي
  /// سبقت التعديل (كانت جلسة واحدة لليوم ⇒ الحصة الأولى).
  ///
  /// بلا `onDelete` (أي `NO ACTION`): حذف حصة لها جلسات ممنوع في القاعدة نفسها،
  /// فوق الحماية التي يفرضها [AppDb.saveLessons].
  IntColumn get lessonId => integer()
      .withDefault(const Constant(1))
      .references(Lessons, #id)();
  TextColumn get openedAt => text()();
  TextColumn get closedAt => text().nullable()();
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
        <Column<Object>>{classId, date, lessonId},
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
  /// الحصة التي تصفها الواقعة. هي جوهر التعديل: التفرّد صار
  /// (طالب، تاريخ، حصة) بدل (طالب، تاريخ)، فيمكن تسجيل الطالب في كل حصة.
  IntColumn get lessonId => integer()
      .withDefault(const Constant(1))
      .references(Lessons, #id)();
  IntColumn get status => integer()();
  IntColumn get source => integer()();
  IntColumn get sessionId => integer().nullable()();
  TextColumn get note => text().nullable()();
  /// وقت الوصول الفعلي `HH:mm` لمن سُجّل حضوره/تأخره (مسحاً أو يدوياً) —
  /// `null` عندما لا يُعرف الوقت (غياب الإقفال التلقائي، سجلات قديمة).
  TextColumn get arrivalTime => text().nullable()();
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
        <Column<Object>>{studentId, date, lessonId},
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
  /// نطاق الحصص داخل كل يوم من أيام الإجازة:
  /// - `null` في الاثنين ⇒ كل حصص اليوم (السلوك القديم: إجازة يوم كامل).
  /// - `3..6` ⇒ من الحصة الثالثة حتى السادسة.
  /// - `1..1` ⇒ الحصة الأولى وحدها (تأخر صباحي/موعد طبي).
  IntColumn get fromSlot => integer().nullable()();
  IntColumn get toSlot => integer().nullable()();
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

/// تنبيهات حد الفصل داخل التطبيق: يُنشأ **مرة واحدة** لكل طالب في السنة
/// لحظة بلوغه الحد الثاني (نفس مصدر إنذار التقارير المبكر)، ولا يتكرر؛
/// إحصاؤه يتحدّث حيًّا ما دام الطالب على القائمة ويُجمَّد بعده.
class AlertNotifications extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get yearId =>
      integer().references(AcademicYears, #id, onDelete: KeyAction.cascade)();
  IntColumn get studentId =>
      integer().references(Students, #id, onDelete: KeyAction.cascade)();
  /// نوع التنبيه (حاليًا حد الفصل فقط) — قابل للامتداد بأنواع قادمة.
  TextColumn get kind => text().withDefault(const Constant('threshold_2'))();
  /// أيام الغياب عند آخر احتساب (يتحدّث ما دام الطالب على القائمة).
  IntColumn get absentDays => integer()();
  /// الأيام المسجّلة عند آخر احتساب (لنسبة السطر).
  IntColumn get recordedDays => integer()();
  /// العتبة الثانية (أيام) وقت الحدث.
  RealColumn get thresholdDays => real()();
  TextColumn get occurredAt => text()();
  /// قرأه المستخدم (فتحها من زر الجرس أو من إشعار النظام).
  BoolColumn get read => boolean().withDefault(const Constant(false))();
  TextColumn get readAt => text().nullable()();
  /// عُرِض إشعار النظام (خارج التطبيق) بنجاح — العرض **مرة واحدة**:
  /// عند الفشل (بلا صلاحية/الميزة مطفأة) يُعاد المحاولة في الاحتساب التالي،
  /// ولا يُعاد أبدًا بعد النجاح.
  BoolColumn get systemShown => boolean().withDefault(const Constant(false))();
  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
        <Column<Object>>{yearId, studentId, kind},
      ];
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
    AlertNotifications,
    Lessons,
  ],
)
class AppDb extends _$AppDb {
  AppDb() : super(_openConnection());

  AppDb.forTesting(super.e);

  /// الإصدار 6: الحصص (`lessons`) والحضور لكل حصة.
  ///
  /// 1. جدول حصص، 2. تنبيهات حد الفصل، 3. هاتف الطالب، 4. وقت الوصول،
  /// 5. تنبيهات النظام، 6. الحضور بالحصة.
  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
          await ensureLessonsSeeded();
          await _ensureIndexes();
          await _ensureLessonIndexes();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // هجرات مرقّمة تُضاف هنا مع كل تغيير مخطط.
          if (from < 2) {
            await _ensureIndexes();
          }
          if (from < 3) {
            await m.addColumn(students, students.phone);
          }
          if (from < 4) {
            // عمود اختياري: السجلات القديمة تبقى بلا وقت ولا يُفقد شيء.
            await m.addColumn(attendanceRows, attendanceRows.arrivalTime);
          }
          if (from < 5) {
            await m.createTable(alertNotifications);
          }
          if (from < 6) {
            await _migrateToLessons(m);
          }
        },
        // بعد الهجرات وقبل أي استعلام: المفاتيح الأجنبية مفعّلة فعلياً (كانت
        // مجرد تعليقات في المخطط لا تُنفَّذ)، والفهارس مضمونة على قواعد سبقت
        // إضافتها. التفعيل هنا لا يمسّ الصفوف القائمة ولا يعطّل هجرة.
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await _ensureIndexes();
          await _ensureLessonIndexes();
        },
      );

  /// هجرة الإصدار 6: يوم كامل ⇒ حصص.
  ///
  /// الترتيب إلزامي:
  /// 1. إنشاء جدول الحصص وزرع الجدول الافتراضي (وإلا فلا مفتاح أجنبي صالح).
  /// 2. إعادة بناء `sessions` و`attendance_rows` بـ`TableMigration` — وهي
  ///    الطريقة الوحيدة في SQLite لإضافة عمود بمفتاح أجنبي **وتغيير قيد
  ///    التفرّد** مع الحفاظ على البيانات (كل سطر قديم ⇒ الحصة الأولى).
  /// 3. أعمدة نطاق الإجازة (اختيارية فلا تحتاج إعادة بناء).
  /// 4. إعادة إنشاء الفهارس: إعادة بناء الجدول تُسقطها.
  Future<void> _migrateToLessons(Migrator m) async {
    await m.createTable(lessons);
    await ensureLessonsSeeded();
    // كل سطر قديم (كان يوماً كاملاً) يُسند إلى **الحصة الأولى** المزروعة، فلا
    // يبقى أي سجل بلا حصة وتبقى التقارير القديمة مقروءة.
    final int firstLessonId = await _firstLessonId();
    await m.alterTable(
      TableMigration(
        sessions,
        newColumns: <GeneratedColumn<Object>>[sessions.lessonId],
        columnTransformer: <GeneratedColumn<Object>, Expression<Object>>{
          sessions.lessonId: Constant<int>(firstLessonId),
        },
      ),
    );
    await m.alterTable(
      TableMigration(
        attendanceRows,
        newColumns: <GeneratedColumn<Object>>[attendanceRows.lessonId],
        columnTransformer: <GeneratedColumn<Object>, Expression<Object>>{
          attendanceRows.lessonId: Constant<int>(firstLessonId),
        },
      ),
    );
    await m.addColumn(leaves, leaves.fromSlot);
    await m.addColumn(leaves, leaves.toSlot);
    // إعادة بناء الجدولين أسقطت فهارسهما: تُعاد هنا وفي كل فتح (IF NOT EXISTS).
    await _ensureIndexes();
    await _ensureLessonIndexes();
  }

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

  /// فهارس بُعد الحصة — تُنشأ **بعد** وجود أعمدة `lesson_id` فقط:
  /// هجرة قاعدة قديمة (from < 2) تستدعي `_ensureIndexes` قبل إضافة الأعمدة.
  Future<void> _ensureLessonIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_attendance_lesson '
      'ON attendance_rows (class_id, date, lesson_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_attendance_student_date_lesson '
      'ON attendance_rows (student_id, date, lesson_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sessions_lesson '
      'ON sessions (class_id, date, lesson_id)',
    );
    // فهرس على العمود وحده: يخدم حارس حذف الحصة (`_lessonUsage`) الذي يسأل
    // «هل توجد سجلات لهذه الحصة؟» بلا بُعد صف/تاريخ في شرطه.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_attendance_lesson_only '
      'ON attendance_rows (lesson_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sessions_lesson_only '
      'ON sessions (lesson_id)',
    );
  }

  // ---------- إعدادات ----------

  /// قيم افتراضية تُدمج عند القراءة فلا تعتمد شاشة على وجود مفتاح مسبق.
  static const Map<String, String> settingDefaults = <String, String>{
    'work_weekdays': '7,1,2,3,4',
    'show_hijri': '1',
    'alert_threshold_1': '10',
    'alert_threshold_2': '15',
    // إشعارات النظام (خارج التطبيق) — مفتوحة افتراضيًا.
    'system_notifications_enabled': '1',
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

  // ---------- الحصص ----------

  /// زرع جدول الحصص الافتراضي إن كان الجدول فارغاً (idempotent).
  ///
  /// يُستدعى في: إنشاء قاعدة جديدة، هجرة الإصدار 6، استعادة نسخة قديمة،
  /// والتصفير الشامل — فلا توجد حالة تعمل فيها الشاشات بجدول حصص فارغ.
  Future<void> ensureLessonsSeeded() async {
    if (await lessonCount() > 0) {
      return;
    }
    for (final LessonTemplate t in LessonSchedule.defaults) {
      await into(lessons).insert(
        LessonsCompanion.insert(
          slot: t.slot,
          start: t.start,
          end: t.end,
          name: Value(t.name),
        ),
      );
    }
    await logAudit('lessons_seed', 'count=${LessonSchedule.defaults.length}');
  }

  Future<int> _firstLessonId() async {
    final Lesson? l = await (select(lessons)
          ..orderBy(<OrderClauseGenerator<Lessons>>[
            (Lessons x) => OrderingTerm.asc(x.slot),
            (Lessons x) => OrderingTerm.asc(x.id),
          ])
          ..limit(1))
        .getSingleOrNull();
    return l?.id ?? 1;
  }

  Future<int> lessonCount() async {
    final TypedResult row = await (selectOnly(lessons)
          ..addColumns(<Expression<int>>[countAll()]))
        .getSingle();
    return row.read(countAll()) ?? 0;
  }

  Future<List<Lesson>> allLessons() => (select(lessons)
        ..orderBy(<OrderClauseGenerator<Lessons>>[
          (Lessons l) => OrderingTerm.asc(l.slot),
          (Lessons l) => OrderingTerm.asc(l.id),
        ]))
      .get();

  Stream<List<Lesson>> watchLessons() => (select(lessons)
        ..orderBy(<OrderClauseGenerator<Lessons>>[
          (Lessons l) => OrderingTerm.asc(l.slot),
          (Lessons l) => OrderingTerm.asc(l.id),
        ]))
      .watch();

  /// نافذة الحصة الجاهزة للاستهلاك في الواجهات والخدمات (بلا اعتماد على Drift).
  static LessonWindow windowOf(Lesson l) => LessonWindow(
        id: l.id,
        slot: l.slot,
        name: l.name,
        start: l.start,
        end: l.end,
      );

  /// كل الحصص كنوافذ مرتبة — المصدر الموحّد لمنتقي الحصص في كل شاشة.
  Future<List<LessonWindow>> lessonWindows() async => <LessonWindow>[
        for (final Lesson l in await allLessons()) windowOf(l),
      ];

  Future<Lesson?> lessonById(int id) =>
      (select(lessons)..where((l) => l.id.equals(id))).getSingleOrNull();

  Future<Lesson?> lessonBySlot(int slot) =>
      (select(lessons)..where((l) => l.slot.equals(slot))).getSingleOrNull();

  /// الحصة الأولى (الأدنى رقماً) — تُستخدم كقيمة احتياطية موثوقة.
  Future<Lesson> firstLesson() async {
    await ensureLessonsSeeded();
    final Lesson? l = await (select(lessons)
          ..orderBy(<OrderClauseGenerator<Lessons>>[
            (Lessons x) => OrderingTerm.asc(x.slot),
            (Lessons x) => OrderingTerm.asc(x.id),
          ])
          ..limit(1))
        .getSingleOrNull();
    if (l == null) {
      // لا يقع عملياً بعد الزرع؛ حماية من قاعدة تالفة.
      throw StateError('لا يوجد جدول حصص');
    }
    return l;
  }

  /// حفظ جدول الحصص كاملاً من المحرر.
  ///
  /// القواعد المحفوظة:
  /// - الترتيب في [drafts] هو ترتيب الحصص: `slot = index + 1`.
  /// - الحصة القائمة تُطابق بـ[id] فتُحدَّث هويتها (اسم/وقت) لا تُستبدل —
  ///   فيبقى كل سجل تاريخي مرتبطاً بحصته الصحيحة.
  /// - حذف حصة **لها سجلات** مرفوض بـ[LessonInUseException] (لا حذف صامت
  ///   لتاريخ)، ويُسمح بحذف حصة بلا سجلات.
  /// - إعادة الترقيم تمرّ بمرحلتين (أرقام مؤقتة سالبة) لتفادي تصادم القيد
  ///   الفريد على `slot` أثناء التبديل.
  Future<void> saveLessons(List<LessonWindow> drafts) async {
    final List<LessonWindow> ordered = <LessonWindow>[
      for (int i = 0; i < drafts.length; i++)
        LessonWindow(
          id: drafts[i].id,
          slot: i + 1,
          name: drafts[i].name.trim(),
          start: drafts[i].start.trim(),
          end: drafts[i].end.trim(),
        ),
    ];
    final String? invalid = LessonSchedule.validate(ordered);
    if (invalid != null) {
      throw FormatException(invalid);
    }
    await transaction<void>(() async {
      final List<Lesson> existing = await allLessons();
      // خريطة ما قبل التعديل: معرّف الحصة ⇒ رقمها. نطاقات الإجازات مخزّنة
      // بالأرقام لا بالمعرّفات، فهذه الخريطة هي مرجع «المعنى التاريخي».
      final Map<int, int> oldSlots = <int, int>{
        for (final Lesson l in existing) l.id: l.slot,
      };
      // 1) تحييد الأرقام الحالية (سالبة = فريدة دائماً في هذا الجدول).
      for (final Lesson l in existing) {
        await (update(lessons)..where((x) => x.id.equals(l.id)))
            .write(LessonsCompanion(slot: Value(-l.id)));
      }
      // 2) تحديث القائم وإدراج الجديد.
      final Set<int> kept = <int>{};
      for (final LessonWindow d in ordered) {
        final bool exists = existing.any((Lesson l) => l.id == d.id);
        if (d.id > 0 && exists) {
          kept.add(d.id);
          await (update(lessons)..where((x) => x.id.equals(d.id))).write(
            LessonsCompanion(
              slot: Value(d.slot),
              name: Value(d.name),
              start: Value(d.start),
              end: Value(d.end),
            ),
          );
        } else {
          final int id = await into(lessons).insert(
            LessonsCompanion.insert(
              slot: d.slot,
              start: d.start,
              end: d.end,
              name: Value(d.name),
            ),
          );
          kept.add(id);
        }
      }
      // 3) نطاقات الإجازات: تُترجم إلى الأرقام الجديدة للحصص نفسها، وقبل
      //    حذف أي حصة، حتى لا يتغيّر معناها التاريخي بلا علم المستخدم.
      final Map<int, int> newSlots = <int, int>{
        for (final LessonWindow d in ordered)
          if (d.id > 0) d.id: d.slot,
      };
      await _translateLeaveScopes(oldSlots: oldSlots, newSlots: newSlots);

      // 4) حذف ما أزاله المستخدم — بعد التأكد أنه بلا سجلات.
      for (final Lesson l in existing) {
        if (kept.contains(l.id)) {
          continue;
        }
        final int used = await _lessonUsage(l.id);
        if (used > 0) {
          throw LessonInUseException(slot: l.slot, records: used);
        }
        await (delete(lessons)..where((x) => x.id.equals(l.id))).go();
      }
    });
    await logAudit('lessons_save', 'count=${ordered.length}');
  }

  /// يترجم نطاقات الإجازات من أرقام الحصص القديمة إلى الجديدة.
  ///
  /// القاعدة: **المجموعة المغطّاة من الحصص تبقى هي نفسها**. لكل إجازة:
  /// 1. تُحسب معرّفات الحصص التي كان نطاقها يغطيها بالخريطة القديمة.
  /// 2. تُترجم هذه المعرّفات إلى أرقامها الجديدة.
  /// 3. إن كانت الأرقام الجديدة متصلة ⇒ يُحدَّث `from_slot/to_slot` عليها.
  ///    وإن تفرّقت ⇒ يُرمى [LeaveScopeConflictException] وتُرتدّ المعاملة.
  ///
  /// ولا تُحذف إجازة ولا يُنقَّص نطاق: الإجازة التي لم يبقَ من حصصها شيء
  /// (حُذفت كلها) تبقى كما هي بلا أثر، ويُسجَّل ذلك في التدقيق.
  Future<void> _translateLeaveScopes({
    required Map<int, int> oldSlots,
    required Map<int, int> newSlots,
  }) async {
    bool changedAny = false;
    final List<Leave> allLeaves = await select(leaves).get();
    for (final Leave l in allLeaves) {
      final int from = l.fromSlot ?? 1;
      final int to = l.toSlot ?? (1 << 30);
      // لا شيء يتغيّر: إجازة «كل الحصص» تبقى كل الحصص.
      if (l.fromSlot == null && l.toSlot == null) {
        continue;
      }
      final List<int> coveredIds = <int>[
        for (final MapEntry<int, int> e in oldSlots.entries)
          if (e.value >= from && e.value <= to) e.key,
      ];
      final List<int> slots = <int>[
        for (final int id in coveredIds)
          if (newSlots[id] != null) newSlots[id]!,
      ]..sort();
      if (slots.isEmpty) {
        continue; // كل حصصها حُذفت: تبقى الإجازة سجلًّا بلا أثر على الحصص.
      }
      final int minSlot = slots.first;
      final int maxSlot = slots.last;
      final bool contiguous = maxSlot - minSlot + 1 == slots.length;
      if (!contiguous) {
        throw LeaveScopeConflictException(
          leaveId: l.id,
          fromSlot: l.fromSlot,
          toSlot: l.toSlot,
          slots: <int>[
            for (final int id in coveredIds) oldSlots[id]!,
          ],
        );
      }
      // لا كتابة بلا داعٍ: النطاق نفسه بالدلالة نفسها (بما فيها «حتى آخر
      // اليوم» حين يبقى آخرَ حصة) يُترك كما هو.
      final int maxNewSlot = newSlots.values.isEmpty
          ? maxSlot
          : newSlots.values.reduce((int a, int b) => a > b ? a : b);
      final bool sameStart = l.fromSlot == minSlot;
      final bool sameEnd = l.toSlot == null
          ? maxSlot == maxNewSlot
          : l.toSlot == maxSlot;
      if (sameStart && sameEnd) {
        continue;
      }
      await (update(leaves)..where((x) => x.id.equals(l.id))).write(
        LeavesCompanion(
          fromSlot: Value(minSlot),
          toSlot: Value(maxSlot),
        ),
      );
      changedAny = true;
    }
    if (changedAny) {
      await logAudit('leaves_reslot', 're-mapped to new lesson numbering');
    }
  }

  /// عدد السجلات التاريخية المرتبطة بحصة (جلسات + حضور) — حارس الحذف.
  Future<int> _lessonUsage(int lessonId) async {
    final TypedResult sessionsRow = await (selectOnly(sessions)
          ..addColumns(<Expression<int>>[countAll()])
          ..where(sessions.lessonId.equals(lessonId)))
        .getSingle();
    final TypedResult rowsRow = await (selectOnly(attendanceRows)
          ..addColumns(<Expression<int>>[countAll()])
          ..where(attendanceRows.lessonId.equals(lessonId)))
        .getSingle();
    return (sessionsRow.read(countAll()) ?? 0) +
        (rowsRow.read(countAll()) ?? 0);
  }

  /// إعادة فتح **كل حصص اليوم** لصف واحد — معاملة واحدة: إمّا تُفتح كلها أو
  /// لا شيء (عكس [closeDaySessions] تماماً). تعيد عدد الحصص التي أُعيد فتحها.
  Future<int> reopenDaySessions({
    required int yearId,
    required int classId,
    required String date,
  }) async => transaction<int>(() async {
        final List<Session> closed = await (select(sessions)
              ..where(
                (s) =>
                    s.yearId.equals(yearId) &
                    s.classId.equals(classId) &
                    s.date.equals(date) &
                    s.closedAt.isNotNull(),
              ))
            .get();
        for (final Session s in closed) {
          await reopenSession(s.id);
        }
        return closed.length;
      });

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
    String? phone,
  }) async =>
      transaction<int>(
        () => _insertStudent(
          yearId: yearId,
          classId: classId,
          fullName: fullName,
          photoPath: photoPath,
          phone: phone,
        ),
      );

  /// الإدراج نفسه بلا معاملة خاصة: يستخدمه الاستيراد داخل معاملته الواحدة.
  Future<int> _insertStudent({
    required int yearId,
    required int classId,
    required String fullName,
    String? photoPath,
    String? phone,
  }) async {
    final int seq = await nextSeqForYear(yearId);
    final int id = await into(students).insert(
      StudentsCompanion(
        yearId: Value(yearId),
        classId: Value(classId),
        fullName: Value(fullName),
        personKey: Value(makePersonKey()),
        seq: Value(seq),
        photoPath: Value(photoPath),
        phone: Value(phone),
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
  }

  /// استيراد أسماء إلى صف واحد بمعاملة واحدة، بالترتيب الوارد من الملف.
  ///
  /// * `seq` يبدأ بعد آخر تسلسل في السنة (`nextSeqForYear`)، فالترتيب محفوظ.
  /// * المكرر داخل القائمة يُسقَط، والمطابق لاسم موجود في الصف يُتخطّى افتراضياً
  ///   (`skipExisting`) ولا يُحذف أو يُعدَّل شيء قائم.
  /// * أي فشل في المنتصف يُرتدّ كاملاً: لا أسماء نصف مستوردة.
  Future<StudentImportOutcome> importStudentNames({
    required int yearId,
    required int classId,
    required List<String> names,
    bool skipExisting = true,
  }) async =>
      transaction<StudentImportOutcome>(() async {
        final List<Student> current = await (select(students)
              ..where((s) => s.classId.equals(classId)))
            .get();
        final Set<String> existing = <String>{
          for (final Student s in current) studentNameKey(s.fullName),
        };
        final Set<String> seen = <String>{};
        int added = 0;
        int dup = 0;
        int skipped = 0;
        int invalid = 0;
        for (final String raw in names) {
          final String name = cleanStudentName(raw);
          if (name.isEmpty || !isImportableName(name)) {
            invalid++;
            continue;
          }
          final String key = studentNameKey(name);
          if (!seen.add(key)) {
            dup++;
            continue;
          }
          if (existing.contains(key) && skipExisting) {
            skipped++;
            continue;
          }
          await _insertStudent(
            yearId: yearId,
            classId: classId,
            fullName: name,
          );
          existing.add(key);
          added++;
        }
        await logAudit(
          'students_import',
          'class=$classId added=$added skipped=$skipped dup=$dup invalid=$invalid',
        );
        return StudentImportOutcome(
          added: added,
          skippedExisting: skipped,
          skippedDuplicate: dup,
          skippedInvalid: invalid,
        );
      });

  /// حذف طالب وكل ما يرتبط به (باجات/حضور/إجازات/أحداث مسح) بمعاملة واحدة.
  Future<void> deleteStudent(int id) async => transaction<void>(() async {
        await (delete(scanEvents)..where((e) => e.studentId.equals(id))).go();
        await (delete(attendanceRows)..where((a) => a.studentId.equals(id))).go();
        await (delete(leaves)..where((l) => l.studentId.equals(id))).go();
        await (delete(badges)..where((b) => b.studentId.equals(id))).go();
        await (delete(alertNotifications)
              ..where((n) => n.studentId.equals(id)))
            .go();
        await (delete(students)..where((s) => s.id.equals(id))).go();
        await logAudit('student_delete', 'id=$id');
      });

  Future<int> countStudentsInClass(int classId) async {
    final List<Student> kids =
        await (select(students)..where((s) => s.classId.equals(classId))).get();
    return kids.length;
  }

  /// حذف صف فارغ فقط (تفرضه الشاشة) مع جلساته.
  ///
  /// الحارس هنا أيضاً لأن المفاتيح الأجنبية مفعّلة الآن: حذف صف فيه طلاب كان
  /// سيحذفهم تلقائياً (cascade) — وهو فقد بيانات صامت لا يجوز.
  Future<void> deleteClass(int classId) async => transaction<void>(() async {
        final int kids = await countStudentsInClass(classId);
        if (kids > 0) {
          throw StateError('لا يمكن حذف صف فيه $kids طالباً — انقلهم أو احذفهم أولاً');
        }
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

  /// جلسة حصة واحدة (صف + تاريخ + حصة) — المفتاح الجديد للتفرّد.
  Future<Session?> sessionOf(int classId, String date, int lessonId) =>
      (select(sessions)
            ..where(
              (s) =>
                  s.classId.equals(classId) &
                  s.date.equals(date) &
                  s.lessonId.equals(lessonId),
            ))
          .getSingleOrNull();

  Stream<Session?> watchSession(int classId, String date, int lessonId) =>
      (select(sessions)
            ..where(
              (s) =>
                  s.classId.equals(classId) &
                  s.date.equals(date) &
                  s.lessonId.equals(lessonId),
            ))
          .watchSingleOrNull();

  /// جلسة حصة برقمها (لنطاقات الإجازات وأدوات العرض) — `null` إن لم تُفتح.
  Future<Session?> sessionForSlot(int classId, String date, int slot) async {
    final Lesson? lesson = await lessonBySlot(slot);
    if (lesson == null) {
      return null;
    }
    return sessionOf(classId, date, lesson.id);
  }

  /// كل جلسات اليوم لصف (حصة لكل صف) مرتبة بترتيب الحصص.
  Future<List<Session>> sessionsOfDay(int classId, String date) =>
      (select(sessions)
            ..where((s) => s.classId.equals(classId) & s.date.equals(date)))
          .get();

  Stream<List<Session>> watchDaySessions(int classId, String date) =>
      (select(sessions)
            ..where((s) => s.classId.equals(classId) & s.date.equals(date)))
          .watch();

  /// فتح جلسة حصة (idempotent): يُعيد القائمة إن كانت مفتوحة سابقاً.
  ///
  /// يستخدمها المسح مباشرة، فتبقى الجلسة الواحدة لكل (صف، تاريخ، حصة) مهما
  /// تكرر الدخول للشاشة أو تبديل الحصص.
  Future<Session> openLessonSession({
    required int yearId,
    required int classId,
    required String date,
    required int lessonId,
  }) async {
    final Session? existing = await sessionOf(classId, date, lessonId);
    if (existing != null) {
      return existing;
    }
    return into(sessions).insertReturning(
      SessionsCompanion(
        yearId: Value(yearId),
        classId: Value(classId),
        date: Value(date),
        lessonId: Value(lessonId),
        openedAt: Value(_now()),
      ),
    );
  }

  /// يفتح جلسات **كل حصص اليوم** لصف — للإقفال الشامل من كشف اليوم.
  Future<List<Session>> ensureDaySessions({
    required int yearId,
    required int classId,
    required String date,
  }) async {
    final List<Lesson> all = await allLessons();
    final List<Session> out = <Session>[];
    for (final Lesson l in all) {
      out.add(
        await openLessonSession(
          yearId: yearId,
          classId: classId,
          date: date,
          lessonId: l.id,
        ),
      );
    }
    return out;
  }

  /// كل سجلات يوم صف (كل الحصص) — للمجاميع اليومية لا لكشف حصة.
  Future<List<AttendanceRow>> attendanceForClassDate(
    int classId,
    String date,
  ) async =>
      (select(attendanceRows)
            ..where((a) => a.classId.equals(classId) & a.date.equals(date)))
          .get();

  /// سجلات حصة واحدة في صف وتاريخ — ما يعرضه كشف الحصة.
  Future<List<AttendanceRow>> attendanceForLesson({
    required int classId,
    required String date,
    required int lessonId,
  }) =>
      (select(attendanceRows)
            ..where(
              (a) =>
                  a.classId.equals(classId) &
                  a.date.equals(date) &
                  a.lessonId.equals(lessonId),
            ))
          .get();

  /// عدد المسجَّلين (حاضر/متأخر/إجازة) في حصة — لعرض «المتبقي”.
  Future<int> recordedCount(int classId, String date, int lessonId) async {
    final List<AttendanceRow> rows = await attendanceForLesson(
      classId: classId,
      date: date,
      lessonId: lessonId,
    );
    return rows
        .where(
          (AttendanceRow r) =>
              r.status == AttendanceStatus.present ||
              r.status == AttendanceStatus.late ||
              r.status == AttendanceStatus.leave,
        )
        .length;
  }

  /// سجل طالب في حصة.
  Future<AttendanceRow?> attendanceOf(
    int studentId,
    String date,
    int lessonId,
  ) async =>
      (select(attendanceRows)
            ..where(
              (a) =>
                  a.studentId.equals(studentId) &
                  a.date.equals(date) &
                  a.lessonId.equals(lessonId),
            ))
          .getSingleOrNull();

  /// خريطة حالة كل طالب في حصة (studentId ⇒ status).
  Future<Map<int, int>> statusesForLesson({
    required int classId,
    required String date,
    required int lessonId,
  }) async {
    final List<AttendanceRow> rows = await attendanceForLesson(
      classId: classId,
      date: date,
      lessonId: lessonId,
    );
    return <int, int>{for (final AttendanceRow r in rows) r.studentId: r.status};
  }

  /// تسجيل/تحديث حالة حضور لطالب في **حصة** (idempotent).
  ///
  /// التفرّد هو (طالب، تاريخ، حصة): سجل الطالب في الحصة الأولى لا علاقة له
  /// بسجله في الثالثة. الإدراج/التحديث صريح لأن `insertOnConflictUpdate`
  /// يستهدف المفتاح الأساسي (id) وحده.
  ///
  /// [arrivalTime] وقت الوصول الفعلي `HH:mm` (للتأخر خصوصاً)؛ تمرير `null`
  /// **يمسح** الوقت المحفوظ — مقصود عند تغيير الحالة يدوياً بلا وقت معروف.
  Future<void> upsertAttendance({
    required int yearId,
    required int classId,
    required int studentId,
    required String date,
    required int lessonId,
    required int status,
    required int source,
    int? sessionId,
    String? note,
    String? arrivalTime,
  }) async {
    final AttendanceRow? existing = await attendanceOf(studentId, date, lessonId);
    if (existing == null) {
      await into(attendanceRows).insert(
        AttendanceRowsCompanion(
          yearId: Value(yearId),
          classId: Value(classId),
          studentId: Value(studentId),
          date: Value(date),
          lessonId: Value(lessonId),
          status: Value(status),
          source: Value(source),
          sessionId: Value(sessionId),
          note: Value(note),
          arrivalTime: Value(arrivalTime),
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
        arrivalTime: Value(arrivalTime),
      ),
    );
  }

  /// هل يقع رقم الحصة داخل نطاق إجازة؟ (`null` في الطرفين = كل الحصص).
  ///
  /// دالة نقية عامة: تستخدمها قاعدة البيانات والواجهات والتصدير بالمنطق نفسه.
  static bool slotInScope(int slot, int? fromSlot, int? toSlot) {
    if (fromSlot == null && toSlot == null) {
      return true;
    }
    final int from = fromSlot ?? 1;
    final int to = toSlot ?? 1 << 30;
    return slot >= from && slot <= to;
  }

  /// هل يغطي الطالبَ إجازةٌ في هذا التاريخ؟ وعند تمرير [slot] هل تشمل حصته؟
  ///
  /// فلترة التاريخ في SQL (فهرس)، وفلترة النطاق في الذاكرة لأنها مقارنة
  /// رقمية بسيطة على صفوف قليلة (إجازات الطالب في يوم واحد).
  Future<bool> isOnLeave(int studentId, String date, {int? slot}) async {
    final List<Leave> covering = await (select(leaves)
          ..where(
            (l) =>
                l.studentId.equals(studentId) &
                l.start.isSmallerOrEqualValue(date) &
                l.end.isBiggerOrEqualValue(date),
          ))
        .get();
    if (covering.isEmpty) {
      return false;
    }
    if (slot == null) {
      return true;
    }
    return covering.any(
      (Leave l) => slotInScope(slot, l.fromSlot, l.toSlot),
    );
  }

  /// وسم التحويل بالمزامنة: يميّز الغياب الذي ألغته إجازة عن إجازة
  /// سجّلها بشر يدوياً — الأول يعود غياباً عند حذف الإجازة والثانية تبقى.
  static const String leaveSyncNote = 'leave-sync';

  /// مزامنة إجازة مع سجلات الحضور داخل نطاقها (تاريخياً وحصةً):
  /// إضافة ⇒ أي غياب (تلقائي أو يدوي) في حصص النطاق يصبح إجازة مع بقاء مصدره؛
  /// حذف ⇒ ما حُوّل بالمزامنة أو وُلّد تلقائياً يعود غياباً إن لم تغطّه
  /// إجازة أخرى. الحضور والتأخر لا يُمسّان أبداً (واقعة حضور ثابتة).
  Future<int> syncLeaveToAttendance({
    required int studentId,
    required String start,
    required String end,
    required bool added,
    int? fromSlot,
    int? toSlot,
  }) async =>
      transaction<int>(() async {
        final Student? st = await studentById(studentId);
        if (st == null) {
          return 0;
        }
        final Map<int, int> slotOf = <int, int>{
          for (final Lesson l in await allLessons()) l.id: l.slot,
        };
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
          final int slot = slotOf[r.lessonId] ?? 1;
          if (!slotInScope(slot, fromSlot, toSlot)) {
            continue;
          }
          if (added && r.status == AttendanceStatus.absent) {
            await upsertAttendance(
              yearId: r.yearId,
              classId: r.classId,
              studentId: r.studentId,
              date: r.date,
              lessonId: r.lessonId,
              status: AttendanceStatus.leave,
              source: r.source,
              sessionId: r.sessionId,
              note: leaveSyncNote,
              arrivalTime: r.arrivalTime,
            );
            changed++;
          } else if (!added &&
              r.status == AttendanceStatus.leave &&
              (r.note == leaveSyncNote ||
                  r.source == AttendanceSource.autoClose)) {
            final bool stillCovered =
                await isOnLeave(studentId, r.date, slot: slot);
            if (!stillCovered) {
              await upsertAttendance(
                yearId: r.yearId,
                classId: r.classId,
                studentId: r.studentId,
                date: r.date,
                lessonId: r.lessonId,
                status: AttendanceStatus.absent,
                source: r.source,
                sessionId: r.sessionId,
                note: null,
                arrivalTime: r.arrivalTime,
              );
              changed++;
            }
          }
        }
        return changed;
      });

  /// حذف تسجيل حضور (تصحيح يدوي من ملف الطالب).
  ///
  /// [lessonId] = `null` يعني حذف سجلات **اليوم كله** (كل الحصص) — مقصود
  /// لزر «مسح تسجيل اليوم»، وتمريره يحذف الحصة وحدها.
  Future<void> deleteAttendance(
    int studentId,
    String date, {
    int? lessonId,
  }) async {
    if (lessonId == null) {
      await (delete(attendanceRows)
            ..where(
              (a) => a.studentId.equals(studentId) & a.date.equals(date),
            ))
          .go();
      return;
    }
    await (delete(attendanceRows)
          ..where(
            (a) =>
                a.studentId.equals(studentId) &
                a.date.equals(date) &
                a.lessonId.equals(lessonId),
          ))
        .go();
  }

  /// إقفال جلسة حصة: كل طالب بلا سجل **في هذه الحصة** وبلا إجازة يغطيها
  /// => غائب. عملية ذرّية. يعيد عدد سجلات الغياب المولّدة.
  Future<int> closeSession(int sessionId) async => transaction<int>(() async {
        final Session? session = await (select(sessions)
              ..where((s) => s.id.equals(sessionId)))
            .getSingleOrNull();
        if (session == null || session.closedAt != null) {
          return 0;
        }
        final Lesson? lesson = await lessonById(session.lessonId);
        final int slot = lesson?.slot ?? 1;
        final List<Student> roster = await (select(students)
              ..where((s) => s.classId.equals(session.classId)))
            .get();
        int generated = 0;
        for (final Student st in roster) {
          final AttendanceRow? existing =
              await attendanceOf(st.id, session.date, session.lessonId);
          if (existing != null) {
            continue;
          }
          if (await isOnLeave(st.id, session.date, slot: slot)) {
            await upsertAttendance(
              yearId: session.yearId,
              classId: session.classId,
              studentId: st.id,
              date: session.date,
              lessonId: session.lessonId,
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
              lessonId: session.lessonId,
              status: AttendanceStatus.absent,
              source: AttendanceSource.autoClose,
              sessionId: sessionId,
            );
          }
          generated++;
        }
        await (update(sessions)..where((s) => s.id.equals(sessionId)))
            .write(SessionsCompanion(closedAt: Value(_now())));
        await logAudit(
          'close_session',
          'session=$sessionId lesson=$slot generated=$generated',
        );
        return generated;
      });

  /// إقفال **كل حصص اليوم** لصف (يفتح الناقص منها أولاً). يعيد مجموع ما وُلّد.
  Future<int> closeDaySessions({
    required int yearId,
    required int classId,
    required String date,
  }) async =>
      transaction<int>(() async {
        final List<Session> sessions = await ensureDaySessions(
          yearId: yearId,
          classId: classId,
          date: date,
        );
        int generated = 0;
        for (final Session s in sessions) {
          generated += await closeSession(s.id);
        }
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

  // ---------- التنبيهات (إشعارات حد الفصل) ----------

  /// تنبيه نوع واحد لطالب في سنة (`null` = لم يبلغ بعد).
  Future<AlertNotification?> alertOf(int yearId, int studentId, String kind) =>
      (select(alertNotifications)
            ..where(
              (n) =>
                  n.yearId.equals(yearId) &
                  n.studentId.equals(studentId) &
                  n.kind.equals(kind),
            ))
          .getSingleOrNull();

  /// كل تنبيهات السنة (تُستخدم للقائمة ولتتبع إشعارات النظام).
  Future<List<AlertNotification>> alertsOfYear(int yearId) =>
      (select(alertNotifications)..where((n) => n.yearId.equals(yearId))).get();

  /// تسجيل بلوغ حد الفصل: إنشاء أول مرة أو تحديث إحصاء بلا تكرار
  /// (idempotent) — يُعيد `true` إذا وُلد التنبيه في هذه النداء.
  Future<bool> recordAlertCrossing({
    required int yearId,
    required int studentId,
    required int absentDays,
    required int recordedDays,
    required double thresholdDays,
    required String kind,
  }) async {
    final AlertNotification? existing = await alertOf(yearId, studentId, kind);
    if (existing == null) {
      await into(alertNotifications).insert(
        AlertNotificationsCompanion(
          yearId: Value(yearId),
          studentId: Value(studentId),
          kind: Value(kind),
          absentDays: Value(absentDays),
          recordedDays: Value(recordedDays),
          thresholdDays: Value(thresholdDays),
          occurredAt: Value(_now()),
        ),
      );
      await logAudit(
        'alert_created',
        'student=$studentId kind=$kind days=$absentDays',
      );
      return true;
    }
    if (existing.absentDays != absentDays ||
        existing.recordedDays != recordedDays ||
        (existing.thresholdDays - thresholdDays).abs() > 0.0001) {
      await (update(alertNotifications)..where((n) => n.id.equals(existing.id)))
          .write(
        AlertNotificationsCompanion(
          absentDays: Value(absentDays),
          recordedDays: Value(recordedDays),
          thresholdDays: Value(thresholdDays),
        ),
      );
    }
    return false;
  }

  /// قائمة الشاشة: غير المقروء أولاً ثم الأحدث.
  Stream<List<AlertNotification>> watchAlerts(int yearId) =>
      (select(alertNotifications)
            ..where((n) => n.yearId.equals(yearId))
            ..orderBy(<OrderClauseGenerator<AlertNotifications>>[
              (t) => OrderingTerm.asc(t.read),
              (t) => OrderingTerm.desc(t.occurredAt),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();

  /// عدّاد زر الجرس: التنبيهات غير المقروءة في السنة.
  Stream<int> unreadAlertCount(int yearId) =>
      (select(alertNotifications)
            ..where((n) => n.yearId.equals(yearId) & n.read.equals(false)))
          .watch()
          .map((List<AlertNotification> rows) => rows.length);

  /// تنبيهات لم يُعرض إشعارها للنظام بعد (بانتظار الصلاحية/الميزة/إقلاع) —
  /// لقاعدة «العرض مرة واحدة مع إعادة المحاولة».
  Future<List<AlertNotification>> pendingSystemAlerts(int yearId) =>
      (select(alertNotifications)
            ..where(
              (n) => n.yearId.equals(yearId) & n.systemShown.equals(false),
            ))
          .get();

  /// عُرِض إشعار النظام بنجاح — لا إعادة عرض.
  Future<void> markAlertSystemShown(int id) =>
      (update(alertNotifications)..where((n) => n.id.equals(id)))
          .write(const AlertNotificationsCompanion(systemShown: Value(true)));

  /// وسم تنبيه واحد كمقروء (فتح من زر الجرس أو من إشعار النظام).
  Future<void> markAlertRead(int id) =>
      (update(alertNotifications)..where((n) => n.id.equals(id)))
          .write(
        AlertNotificationsCompanion(
          read: const Value(true),
          readAt: Value(_now()),
        ),
      );

  /// وسم كل تنبيهات السنة مقروءة — يعيد عدد ما وُسِم.
  Future<int> markAllAlertsRead(int yearId) =>
      (update(alertNotifications)
            ..where((n) => n.yearId.equals(yearId) & n.read.equals(false)))
          .write(
        AlertNotificationsCompanion(
          read: const Value(true),
          readAt: Value(_now()),
        ),
      );

  /// تدفق مدخلات إعادة احتساب التنبيهات: أي تغيير في الحضور/الإعدادات/
  /// الطلاب/السنة/التنبيهات ⇒ احتساب واحد (بلا لمس كل شاشة) — ويبقى
  /// المصدر هو تقارير `ReportsService` نفسها.
  Stream<void> watchAlertInputs() =>
      customSelect(
        'SELECT 1 AS x',
        readsFrom: {
          attendanceRows,
          sessions,
          settings,
          students,
          academicYears,
          alertNotifications,
          lessons,
        },
      )
          .watch()
          .map<void>((_) {});

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
