/// النسخ الاحتياطي والاسترجاع والدمج بين الأجهزة.
///
/// الصيغة 2 (حالية): حاوية zip واحدة —
/// - `backup.json`: البيان — كل الجداول (ومنها سجل التدقيق) + الإعدادات.
/// - `photos/<id الطالب>.<ext>`: ملفات صور الطلاب.
/// الصيغة 1 (قديمة): ملف JSON وحده بلا صور ولا تدقيق — تُقرأ للاسترجاع
/// والدمج كما هي. التعرف بالبصمة السحرية (`PK\x03\x04`) لا بامتداد الملف،
/// فإعادة التسمية لا تكسر الاسترجاع.
///
/// مسارات الصور في البيان تخص الجهاز المصدِّر؛ عند الاسترجاع تُثبَّت صور
/// الحاوية في مخزن الجهاز الجديد وتُعاد كتابة المسارات — ومن لا صورة له
/// في الحاوية يبقى مساره كما هو (ينفع الاسترجاع على الجهاز نفسه).
///
/// قواعد الدمج الآمن:
/// - الجلسات: عدم تكرار (classId+date).
/// - الحضور: عدم الكتابة فوق سجل موجود (الأقدم موثوق).
/// - الدمج تراكمي للجلسات والحضور والمسح فقط؛ لا يمسّ الطلاب والصور والتدقيق.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/school_time.dart';
import 'backup_download_store.dart';
import 'db.dart';
import 'photo_store.dart';

/// تثبيت صورة مسترجعة في المخزن الدائم — يُحقَن في الاختبارات بمجلد
/// مؤقت. الافتراضي [PhotoStore.install].
typedef PhotoInstaller = Future<String> Function(String fileName, List<int> bytes);

/// نسخة مفكوكة: البيان + صورها الخام مفهرسة باسم المدخل في الحاوية.
class _DecodedBackup {
  const _DecodedBackup(this.manifest, this.photos);

  final Map<String, Object?> manifest;
  final Map<String, List<int>> photos;
}

class BackupService {
  BackupService(this.db, {PhotoInstaller? photoInstaller})
      : _installPhoto = photoInstaller ?? PhotoStore.install;

  final AppDb db;
  final PhotoInstaller _installPhoto;

  static const String manifestName = 'backup.json';
  static const String photosPrefix = 'photos/';
  static const int backupVersion = 2;

  Future<Map<String, Object?>> _snapshot() async => <String, Object?>{
        'format': 'student-hodor-backup',
        'version': backupVersion,
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
        'auditLogs': _rows(await db.select(db.auditLogs).get()),
      };

  List<Map<String, Object?>> _rows(List<DataClass> rows) =>
      rows.map((DataClass r) => r.toJson()).toList();

  /// بايتات النسخة (zip: البيان + الصور) — منفصلة عن الكتابة للملف
  /// لتكون قابلة للاختبار دون مجلدات الجهاز.
  Future<Uint8List> exportBytes() async {
    final Archive archive = Archive();
    final List<int> jsonBytes = utf8.encode(
      const JsonEncoder.withIndent(' ').convert(await _snapshot()),
    );
    archive.addFile(ArchiveFile(manifestName, jsonBytes.length, jsonBytes));
    for (final Student s in await db.select(db.students).get()) {
      final String? photoPath = s.photoPath;
      if (photoPath == null || photoPath.isEmpty) {
        continue;
      }
      final File f = File(photoPath);
      if (!f.existsSync()) {
        continue;
      }
      String ext = p.extension(photoPath);
      if (ext.isEmpty) {
        ext = '.jpg';
      }
      try {
        final List<int> bytes = await f.readAsBytes();
        final String name = '$photosPrefix${s.id}$ext';
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      } catch (_) {
        continue; // صورة مقفلة/تالفة: تُتخطى ولا تُسقط النسخة كلها.
      }
    }
    final List<int>? zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw StateError('zip encode returned null');
    }
    return Uint8List.fromList(zipBytes);
  }

  /// اسم نسخة مميز: «نسخة احتياطية - <السبب> - <التاريخ> - <الوقت>.zip»
  /// حتى تُعرف كل نسخة في مجلد التنزيلات بمحتواها وزمنها ولا تختلط.
  /// محارف أسماء الملفات الممنوعة تُستبدل شرطةً (كأسماء ملفات التصدير).
  static String backupFileName({required String reason, DateTime? stamp}) {
    final DateTime t = stamp ?? DateTime.now();
    final String date = SchoolTime.dateKey(t);
    final String time = '${t.hour.toString().padLeft(2, '0')}'
        '-${t.minute.toString().padLeft(2, '0')}'
        '-${t.second.toString().padLeft(2, '0')}';
    final String safeReason = reason
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return 'نسخة احتياطية - $safeReason - $date - $time.zip';
  }

  /// النسخة الإجبارية قبل العمليات المدمرة (حذف سنة/تصفير شامل): تُحفظ
  /// في مجلد التنزيلات العام «نسخة احتياطية للغيابات» باسم مميز متى أمكن
  /// ([BackupDownloadStore]) وإلا في مجلد التطبيق الخاص بالاسم المميز
  /// نفسه. يعيد المسار/الاسم الذي يُعرض للمستخدم.
  Future<String> exportBeforeDestructive({required String reason}) async {
    final Uint8List bytes = await exportBytes();
    final String name = backupFileName(reason: reason);
    final String? sharedPath = await BackupDownloadStore.save(
      fileName: name,
      bytes: bytes,
    );
    if (sharedPath != null) {
      await db.logAudit('backup_downloads', '$reason => $sharedPath');
      return sharedPath;
    }
    final Directory dir = await getApplicationDocumentsDirectory();
    final File f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes, flush: true);
    await db.logAudit('backup_export', '$reason => ${f.path}');
    return f.path;
  }

  /// يكتب نسخة احتياطية كاملة ويعيد مسار الملف.
  Future<String> exportFile() async {
    final Uint8List bytes = await exportBytes();
    final Directory dir = await getApplicationDocumentsDirectory();
    final String name =
        'student-hodor-backup-${DateTime.now().millisecondsSinceEpoch}.zip';
    final File f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes, flush: true);
    await db.logAudit('backup_export', name);
    return f.path;
  }

  /// استرجاع كامل (يستبدل كل شيء: البيانات والصور والسجل) — يجب
  /// استدعاؤه بعد تأكيد المستخدم. يقبل حاوية zip (الصيغة 2) وملف
  /// JSON عادماً (الصيغة 1).
  Future<void> restoreFull(Uint8List bytes) async {
    final _DecodedBackup decoded = _decode(bytes);
    _assertFormat(decoded.manifest);
    // الصور أولاً خارج المعاملة: ملفات يتيمة عند فشل لاحق أهون من
    // معاملة مفتوحة على عمليات ملفات بطيئة.
    final Map<int, String> installed = await _installPhotos(decoded);
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
      await db.delete(db.auditLogs).go();
      await db.delete(db.settings).go();
      await _insertAll(decoded.manifest, photoPaths: installed);
      await db.logAudit('backup_restore_full', '');
    });
  }

  /// دمج جلسة/جهاز آخر: لا يكتب فوق الموجود أبداً. يقبل الحاوية
  /// وملف JSON (تُستخرج الجلسات والحضور والمسح وتُتجاهل الصور).
  Future<Map<String, int>> mergeImport(Uint8List bytes) async {
    final Map<String, Object?> data = _decode(bytes).manifest;
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

  /// يفكّ بايتات النسخة: حاوية zip أو JSON عادماً.
  _DecodedBackup _decode(Uint8List bytes) {
    if (_isZip(bytes)) {
      return _decodeZip(bytes);
    }
    try {
      return _DecodedBackup(
        jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
        const <String, List<int>>{},
      );
    } catch (e) {
      throw FormatException('الملف ليس نسخة احتياطية صالحة: $e');
    }
  }

  _DecodedBackup _decodeZip(Uint8List bytes) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('تعذر فك حاوية النسخة: $e');
    }
    List<int>? manifestBytes;
    final Map<String, List<int>> photos = <String, List<int>>{};
    for (final ArchiveFile f in archive) {
      if (f.name.endsWith('/')) {
        continue; // مدخل مجلد: لا شيء يُقرأ منه.
      }
      if (f.name == manifestName && manifestBytes == null) {
        manifestBytes = f.content as List<int>;
      } else if (f.name.startsWith(photosPrefix)) {
        photos[f.name] = f.content as List<int>;
      }
    }
    if (manifestBytes == null) {
      throw const FormatException('حاوية النسخة بلا بيان (backup.json)');
    }
    try {
      return _DecodedBackup(
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, Object?>,
        photos,
      );
    } catch (e) {
      throw FormatException('بيان النسخة تالف: $e');
    }
  }

  static bool _isZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;

  /// يثبّت صور الحاوية (`photos/<id>.<ext>`) في مخزن الجهاز ويعيد
  /// مساراتها الجديدة مفهرسة برقم الطالب.
  ///
  /// أسماء المداخل لا تُكتب للقرص أبداً (درء Zip-Slip): المطابقة بنمط
  /// صارم، والتثبيت بالاسم المجرّد من أي مسار عبر [PhotoStore.install]
  /// الذي يجرّده بدوره.
  Future<Map<int, String>> _installPhotos(_DecodedBackup decoded) async {
    if (decoded.photos.isEmpty) {
      return const <int, String>{};
    }
    final RegExp entry = RegExp(r'^photos/(\d+)\.[A-Za-z0-9]+$');
    final Map<int, String> byId = <int, String>{};
    for (final String name in decoded.photos.keys) {
      final RegExpMatch? m = entry.firstMatch(name);
      if (m != null) {
        byId[int.parse(m.group(1)!)] ??= name;
      }
    }
    final Map<int, String> installed = <int, String>{};
    for (final MapEntry<int, String> e in byId.entries) {
      try {
        installed[e.key] = await _installPhoto(
          p.basename(e.value),
          decoded.photos[e.value]!,
        );
      } catch (_) {
        continue; // صورة حاوية تالفة: تُتخطى ويُكمل الاسترجاع.
      }
    }
    return installed;
  }

  void _assertFormat(Map<String, Object?> data) {
    if (data['format'] != 'student-hodor-backup') {
      throw const FormatException('الملف ليس من تنسيق نسخ هذا النظام');
    }
  }

  Future<void> _insertAll(
    Map<String, Object?> data, {
    Map<int, String> photoPaths = const <int, String>{},
  }) async {
    for (final Map<String, Object?> r in _list(data['years'])) {
      await db.into(db.academicYears).insert(AcademicYear.fromJson(r).toCompanion(false));
    }
    for (final Map<String, Object?> r in _list(data['classes'])) {
      await db.into(db.schoolClasses).insert(SchoolClass.fromJson(r).toCompanion(false));
    }
    for (final Map<String, Object?> r in _list(data['students'])) {
      StudentsCompanion c = Student.fromJson(r).toCompanion(false);
      // مسار الصورة في البيان يخص الجهاز المصدِّر؛ إن جاءت صورته في
      // الحاوية ثُبّتت محلياً وحلّ مسارها الجديد محلّه.
      final int? id = c.id.present ? c.id.value : null;
      final String? installed = id == null ? null : photoPaths[id];
      if (installed != null) {
        c = c.copyWith(photoPath: Value(installed));
      }
      await db.into(db.students).insert(c);
    }
    for (final Map<String, Object?> r in _list(data['badges'])) {
      await db.into(db.badges).insert(Badge.fromJson(r).toCompanion(false));
    }
    for (final Map<String, Object?> r in _list(data['sessions'])) {
      await db.into(db.sessions).insert(Session.fromJson(r).toCompanion(false));
    }
    for (final Map<String, Object?> r in _list(data['attendance'])) {
      await db
          .into(db.attendanceRows)
          .insert(AttendanceRow.fromJson(r).toCompanion(false));
    }
    for (final Map<String, Object?> r in _list(data['scanEvents'])) {
      await db.into(db.scanEvents).insert(ScanEvent.fromJson(r).toCompanion(false));
    }
    for (final Map<String, Object?> r in _list(data['leaves'])) {
      await db.into(db.leaves).insert(Leave.fromJson(r).toCompanion(false));
    }
    for (final Map<String, Object?> r in _list(data['holidays'])) {
      await db.into(db.holidays).insert(Holiday.fromJson(r).toCompanion(false));
    }
    for (final Map<String, Object?> r in _list(data['auditLogs'])) {
      await db.into(db.auditLogs).insert(AuditLog.fromJson(r).toCompanion(false));
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
      final SessionsCompanion c = Session.fromJson(r).toCompanion(false);
      final Session? existing = await (db.select(db.sessions)
            ..where(
              (s) =>
                  s.classId.equals(c.classId.value) & s.date.equals(c.date.value),
            ))
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
      final AttendanceRowsCompanion c = AttendanceRow.fromJson(r).toCompanion(false);
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
      await db.into(db.scanEvents).insert(ScanEvent.fromJson(r).toCompanion(false));
      n++;
    }
    return n;
  }
}
