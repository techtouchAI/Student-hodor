/// دورة حياة السنة الدراسية: إنشاء، إنهاء، ترقية، تدوير مع إبقاء الأسماء، تصفير.
library;

import 'package:drift/drift.dart';

import '../core/badge_code.dart';
import '../core/school_time.dart';
import 'backup_service.dart';
import 'db.dart';
import 'photo_store.dart';

class YearsService {
  YearsService(this.db);

  final AppDb db;

  Future<int> createYear({
    required String name,
    required DateTime start,
    required DateTime end,
    required bool activate,
  }) async {
    final int id = await db.into(db.academicYears).insert(
          AcademicYearsCompanion(
            name: Value(name),
            start: Value(SchoolTime.dateKey(start)),
            end: Value(SchoolTime.dateKey(end)),
            active: Value(activate),
          ),
        );
    if (activate) {
      await _singleActive(id);
    }
    await db.logAudit('year_create', name);
    return id;
  }

  Future<void> activateYear(int id) async {
    await _singleActive(id);
    await db.logAudit('year_activate', 'id=$id');
  }

  Future<void> _singleActive(int id) async => db.transaction<void>(() async {
        await (db.update(db.academicYears))
            .write(const AcademicYearsCompanion(active: Value(false)));
        await (db.update(db.academicYears)..where((y) => y.id.equals(id)))
            .write(const AcademicYearsCompanion(active: Value(true)));
      });

  /// إنهاء السنة: أرشفة للقراءة فقط مع بقاء التقارير متاحة.
  Future<void> closeYear(int id) async {
    await (db.update(db.academicYears)..where((y) => y.id.equals(id))).write(
      AcademicYearsCompanion(
        closed: const Value(true),
        active: const Value(false),
        closedAt: Value(DateTime.now().toIso8601String()),
      ),
    );
    await db.logAudit('year_close', 'id=$id');
  }

  /// ترقية طلاب سنة إلى صفوف سنة جديدة مع بادجات جديدة.
  /// [mapping] من classId القديم إلى classId الجديد.
  Future<int> promote({
    required int fromYearId,
    required int toYearId,
    required Map<int, int> mapping,
    required String schoolName,
    required int yearShort,
  }) async =>
      db.transaction<int>(() async {
        final List<Student> students = await (db.select(db.students)
              ..where((s) => s.yearId.equals(fromYearId)))
            .get();
        int n = 0;
        for (final Student s in students) {
          final int? toClass = mapping[s.classId];
          if (toClass == null) {
            continue;
          }
          final int nextSeq = await db.nextSeqForYear(toYearId);
          final int newId = await db.into(db.students).insert(
                StudentsCompanion(
                  yearId: Value(toYearId),
                  classId: Value(toClass),
                  fullName: Value(s.fullName),
                  personKey: Value(s.personKey),
                  seq: Value(nextSeq),
                  photoPath: Value(s.photoPath),
                  phone: Value(s.phone),
                  createdAt: Value(DateTime.now().toIso8601String()),
                ),
              );
          await db.into(db.badges).insert(
                BadgesCompanion(
                  studentId: Value(newId),
                  code: Value(
                    BadgeCode.make(
                      schoolName: schoolName,
                      sequence: nextSeq,
                      yearShort: yearShort,
                    ),
                  ),
                  issuedAt: Value(DateTime.now().toIso8601String()),
                ),
              );
          n++;
        }
        await db.logAudit('year_promote', 'from=$fromYearId to=$toYearId n=$n');
        return n;
      });

  /// «تصفير عداد الغيابات مع إبقاء أسماء التلاميذ»: سنة جديدة فعّالة + أرشفة
  /// القديمة + نقل كل الطلاب لصفوف مطابقة الاسم (تُنشأ إن غابت) ببادجات جديدة.
  Future<int> rolloverKeepNames({
    required DateTime newStart,
    required DateTime newEnd,
  }) async {
    final AcademicYear? cur = await db.activeYear();
    if (cur == null) {
      return 0;
    }
    final int newId = await createYear(
      name: '${newStart.year}-${newStart.year + 1}',
      start: newStart,
      end: newEnd,
      activate: true,
    );
    await closeYear(cur.id);
    final List<SchoolClass> from = await (db.select(db.schoolClasses)
          ..where((c) => c.yearId.equals(cur.id)))
        .get();
    final Map<int, int> mapping = <int, int>{};
    for (final SchoolClass c in from) {
      SchoolClass? to = await (db.select(db.schoolClasses)
            ..where(
              (x) =>
                  x.yearId.equals(newId) &
                  x.grade.equals(c.grade) &
                  x.section.equals(c.section),
            ))
          .getSingleOrNull();
      to ??= await db.into(db.schoolClasses).insertReturning(
            SchoolClassesCompanion(
              yearId: Value(newId),
              grade: Value(c.grade),
              section: Value(c.section),
            ),
          );
      mapping[c.id] = to.id;
    }
    final String school = await db.setting('school_name') ?? '';
    final String startKey = SchoolTime.dateKey(newStart);
    final int yearShort = int.tryParse(startKey.substring(2, 4)) ?? 0;
    final int n = await promote(
      fromYearId: cur.id,
      toYearId: newId,
      mapping: mapping,
      schoolName: school,
      yearShort: yearShort,
    );
    await db.logAudit('year_rollover', 'from=${cur.id} to=$newId n=$n');
    return n;
  }

  /// حذف سنة دراسية **واحدة** وكل ما يخصها وحدها: صفوفها، طلابها وصورهم،
  /// حضورها، إجازاتها، جلساتها وأحداث مسحها، بادجاتها — بنسخة احتياطية
  /// إجبارية أولاً تماماً كالتصفير الشامل ([resetAll]) لكن بنطاق السنة
  /// المحددة؛ بقية السنوات وبياناتها لا تُمس.
  ///
  /// [backup] حقن مولّد النسخة للاختبارات؛ في الميدان تُنشأ نسخة إجبارية
  /// باسم مميز في مجلد التنزيلات عبر
  /// [BackupService.exportBeforeDestructive] قبل أي حذف.
  Future<String> deleteYear(
    int yearId, {
    Future<String> Function()? backup,
  }) async {
    final AcademicYear? target = await db.yearById(yearId);
    final String yearName = target?.name ?? 'رقم $yearId';
    // نسخة إجبارية باسم مميز (التاريخ + سبب الحذف) في مجلد التنزيلات.
    final Future<String> Function() makeBackup = backup ??
        (() => BackupService(db)
            .exportBeforeDestructive(reason: 'حذف السنة $yearName'));
    final String backupPath = await makeBackup();
    await db.transaction<void>(() async {
      // أحداث المسح تشير للجلسات بلا قيد حذف — تُنظف صراحة أولاً.
      final List<Session> sessions = await (db.select(db.sessions)
            ..where((s) => s.yearId.equals(yearId)))
          .get();
      for (final Session s in sessions) {
        await (db.delete(db.scanEvents)
              ..where((e) => e.sessionId.equals(s.id)))
            .go();
      }
      await (db.delete(db.attendanceRows)
            ..where((a) => a.yearId.equals(yearId)))
          .go();
      await (db.delete(db.leaves)..where((l) => l.yearId.equals(yearId))).go();
      final List<Student> kids = await (db.select(db.students)
            ..where((s) => s.yearId.equals(yearId)))
          .get();
      if (kids.isNotEmpty) {
        await (db.delete(db.badges)
              ..where(
                (b) => b.studentId
                    .isIn(<int>[for (final Student s in kids) s.id]),
              ))
            .go();
      }
      // صور الطلاب ملفات على القرص — حذفها مع صفوف أصحابها (بلا استثناءات:
      // ملف مفقود لا يجوز أن يعطّل الحذف).
      for (final Student s in kids) {
        try {
          await PhotoStore.deleteIfExists(s.photoPath);
        } catch (_) {
          // صورة تالفة/مقفلة: يُكمل الحذف.
        }
      }
      await (db.delete(db.students)..where((s) => s.yearId.equals(yearId)))
          .go();
      await (db.delete(db.sessions)..where((s) => s.yearId.equals(yearId)))
          .go();
      await (db.delete(db.schoolClasses)
            ..where((c) => c.yearId.equals(yearId)))
          .go();
      await (db.delete(db.academicYears)..where((y) => y.id.equals(yearId)))
          .go();
      await db.logAudit('year_delete', 'year=$yearId backup=$backupPath');
    });
    return backupPath;
  }

  /// تصفير شامل: نسخة احتياطية إجبارية أولاً ثم مسح كل الجداول.
  Future<String> resetAll() async {
    final String backupPath = await BackupService(db)
        .exportBeforeDestructive(reason: 'تصفير شامل');
    await db.transaction<void>(() async {
      await db.delete(db.scanEvents).go();
      await db.delete(db.attendanceRows).go();
      await db.delete(db.sessions).go();
      await db.delete(db.leaves).go();
      await db.delete(db.badges).go();
      await db.delete(db.students).go();
      await db.delete(db.schoolClasses).go();
      await db.delete(db.academicYears).go();
      await db.delete(db.holidays).go();
      await db.delete(db.settings).go();
      await db.logAudit('reset_all', 'backup=$backupPath');
    });
    return backupPath;
  }
}
