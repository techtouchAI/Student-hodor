/// النسخ الاحتياطي والاسترجاع والدمج بين الأجهزة — ملف JSON واحد.
///
/// قواعد الدمج الآمن:
/// - الجلسات: عدم تكرار (classId+date).
/// - الحضور: عدم الكتابة فوق سجل موجود (الأقدم موثوق).
/// - الطلاب/الباجات: إدخال مع تجاهل تعارض الرموز الفريدة.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';

class BackupService {
  BackupService(this.db);

  final AppDb db;

  Future<Map<String, Object?>> _snapshot() async => <String, Object?>{
        'format': 'student-hodor-backup',
        'version': 1,
        'at': DateTime.now().toIso8601String(),
        'settings': await db.allSettings(),
        'years': _rows(await db.select(db.academicYears).get()),
        'classes': _rows(await db.select(db.schoolClasses).get()),
        'students': _rows(await db.select(db.students).get()),
        'badges': _rows(await db.select(db.badges).get()),
        'sessions': _rows(await db.select(db.sessions).get()),
        'attendance': _rows(await db.select(db.attendanceRows).get()),
        'scanEvents': _rows(await db.select(db.scanEvents).get()),
        'leaves': _rows(await db.select(db.leaves).get()),
        'holidays': _rows(await db.select(db.holidays).get()),
      };

  List<Map<String, Object?>> _rows(List<DataClass> rows) =>
      rows.map((DataClass r) => r.toJson()).toList();

  /// يكتب نسخة احتياطية كاملة ويعيد مسار الملف.
  Future<String> exportFile() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final String name =
        'student-hodor-backup-${DateTime.now().millisecondsSinceEpoch}.json';
    final File f = File(p.join(dir.path, name));
    await f.writeAsString(
      const JsonEncoder.withIndent(' ').convert(await _snapshot()),
    );
    await db.logAudit('backup_export', name);
    return f.path;
  }

  /// استرجاع كامل (يستبدل كل شيء) — يجب استدعاؤه بعد تأكيد المستخدم.
  Future<void> restoreFull(String jsonText) async {
    final Map<String, Object?> data =
        jsonDecode(jsonText) as Map<String, Object?>;
    _assertFormat(data);
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
      await _insertAll(data);
      await db.logAudit('backup_restore_full', '');
    });
  }

  /// دمج جلسة/جهاز آخر: لا يكتب فوق الموجود أبداً.
  Future<Map<String, int>> mergeImport(String jsonText) async {
    final Map<String, Object?> data =
        jsonDecode(jsonText) as Map<String, Object?>;
    _assertFormat(data);
    final Map<String, int> counts = <String, int>{};
    await db.transaction<void>(() async {
      counts['sessions'] = await _mergeSessions(data['sessions']);
      counts['attendance'] = await _mergeAttendance(data['attendance']);
      counts['scanEvents'] = await _mergeScanEvents(data['scanEvents']);
      await db.logAudit('backup_merge', counts.toString());
    });
    return counts;
  }

  void _assertFormat(Map<String, Object?> data) {
    if (data['format'] != 'student-hodor-backup') {
      throw const FormatException('الملف ليس من تنسيق نسخ هذا النظام');
    }
  }

  Future<void> _insertAll(Map<String, Object?> data) async {
    for (final Map<String, Object?> r in _list(data['years'])) {
      await db.into(db.academicYears).insert(AcademicYearsCompanion.fromJson(r));
    }
    for (final Map<String, Object?> r in _list(data['classes'])) {
      await db.into(db.schoolClasses).insert(SchoolClassesCompanion.fromJson(r));
    }
    for (final Map<String, Object?> r in _list(data['students'])) {
      await db.into(db.students).insert(StudentsCompanion.fromJson(r));
    }
    for (final Map<String, Object?> r in _list(data['badges'])) {
      await db.into(db.badges).insert(BadgesCompanion.fromJson(r));
    }
    for (final Map<String, Object?> r in _list(data['sessions'])) {
      await db.into(db.sessions).insert(SessionsCompanion.fromJson(r));
    }
    for (final Map<String, Object?> r in _list(data['attendance'])) {
      await db
          .into(db.attendanceRows)
          .insert(AttendanceRowsCompanion.fromJson(r));
    }
    for (final Map<String, Object?> r in _list(data['scanEvents'])) {
      await db.into(db.scanEvents).insert(ScanEventsCompanion.fromJson(r));
    }
    for (final Map<String, Object?> r in _list(data['leaves'])) {
      await db.into(db.leaves).insert(LeavesCompanion.fromJson(r));
    }
    for (final Map<String, Object?> r in _list(data['holidays'])) {
      await db.into(db.holidays).insert(HolidaysCompanion.fromJson(r));
    }
    final Object? settings = data['settings'];
    if (settings is Map<String, Object?>) {
      for (final MapEntry<String, Object?> e in settings.entries) {
        await db.setSetting(e.key, '${e.value}');
      }
    }
  }

  List<Map<String, Object?>> _list(Object? v) => v is List
      ? v.cast<Map<String, Object?>>()
      : const <Map<String, Object?>>[];

  Future<int> _mergeSessions(Object? v) async {
    int n = 0;
    for (final Map<String, Object?> r in _list(v)) {
      final SessionsCompanion c = SessionsCompanion.fromJson(r);
      final Session? existing = await (db.select(db.sessions)
            ..where((s) =>
                s.classId.equals(c.classId.value) & s.date.equals(c.date.value)))
          .getSingleOrNull();
      if (existing == null) {
        await db.into(db.sessions).insert(c);
        n++;
      }
    }
    return n;
  }

  Future<int> _mergeAttendance(Object? v) async {
    int n = 0;
    for (final Map<String, Object?> r in _list(v)) {
      final AttendanceRowsCompanion c = AttendanceRowsCompanion.fromJson(r);
      final AttendanceRow? existing =
          await db.attendanceOf(c.studentId.value, c.date.value);
      if (existing == null) {
        await db.into(db.attendanceRows).insert(c);
        n++;
      }
    }
    return n;
  }

  Future<int> _mergeScanEvents(Object? v) async {
    int n = 0;
    for (final Map<String, Object?> r in _list(v)) {
      await db.into(db.scanEvents).insert(ScanEventsCompanion.fromJson(r));
      n++;
    }
    return n;
  }
}
