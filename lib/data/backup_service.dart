/// النسخ الاحتياطي والاستعادة الكاملة.
///
/// الصيغة 3 (حالية): حاوية zip واحدة —
/// - `backup.json`: البيان — كل الجداول (ومنها **جدول الحصص** وسجل التدقيق)
///   + الإعدادات. أعمدة `lesson_id` ونطاق الإجازة تُلتقط تلقائياً لأنها في
///   `toJson` لكل صف.
/// - `photos/<id الطالب>.<ext>`: ملفات صور الطلاب.
/// الصيغة 2: حاوية zip بلا جدول حصص (نسخة ما قبل الحصص).
/// الصيغة 1 (قديمة): ملف JSON وحده بلا صور ولا تدقيق.
///
/// **الاستعادة استبدال لا دمج.** لا توجد في هذا الإصدار أي عملية دمج: عملية
/// واحدة `restoreFull` تحذف بيانات التطبيق الحالية وتكتب بيانات النسخة
/// كاملةً، بعد تحقق مسبق وقبول المستخدم. (قرار معماري موثّق في
/// `docs/PLAN-2026-10-RESTORE-ar.md` و`docs/RESTORE-FULL-ar.md`.)
///
/// دلالات الحصص عند الاستعادة — سياستان لا تُخلطان:
/// 1. **نسخة قديمة بلا جدول حصص** (صيغة 1/2، أو بيان بلا `lessons`): يُزرع
///    الجدول الافتراضي، وكل سطر قديم بلا مرجع (جلسة/حضور) يُسند إلى الحصة
///    الأولى. هذا هو تعريف الترحيل الرسمي: اليوم كان حصة واحدة، فالسطر يقرأ
///    كما كان ولا يُفقد شيء.
/// 2. **نسخة حديثة فيها جدول حصص**: كل `lesson_id` يجب أن يوجد فعلاً. المرجع
///    المجهول أو المفقود **خلل سلامة بيانات يُرفض قبل أي كتابة**، ولا يُسند
///    تلقائياً إلى الحصة الأولى — لأن ذلك يغيّر معنى سجل تاريخي بلا علم أحد.
///
/// مسارات الصور في البيان تخص الجهاز المصدِّر؛ عند الاستعادة تُثبَّت صور
/// الحاوية في مخزن الجهاز الجديد وتُعاد كتابة المسارات — ومن لا صورة له
/// في الحاوية يبقى مساره كما هو (ينفع الاستعادة على الجهاز نفسه).
///
/// **دورة حياة ملفات الصور:** التثبيت يسبق المعاملة، فمسار الفشل لا يترك
/// ملفات يتيمة: كل ملف أنشأته المحاولة يُسجَّل، وعند الفشل تُحذف هذه الملفات
/// وحدها — لا ملف كان موجوداً قبل المحاولة، ولا ملف يشير إليه سجل قائم في
/// القاعدة (بعد التراجع). إن فشلت قراءة قائمة الصور السابقة يُلغى التنظيف
/// كله ويُذكر ذلك في رسالة الخطأ. عند النجاح تبقى الصور الجديدة ولا يُحذف
/// شيء قديم (`docs/RESTORE-FULL-ar.md`).
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

/// يقرأ مسارات الصور الموجودة **قبل** الاستعادة.
///
/// الافتراضي [PhotoStore.existingPaths] (مجلد مستندات التطبيق). يُحقَن في
/// الاختبارات بلا `path_provider`، وغيابه (`null` من الاستدعاء) يعني «غير
/// معروف» ⇒ لا يُحذف أي ملف صورة بعد فشل الاستعادة.
typedef PhotoSnapshotter = Future<Set<String>> Function();

/// نسخة تالفة البنية أو غير متسقة المراجع: تُرفض **قبل** أي كتابة على القاعدة،
/// فبيانات المستخدم الحالية تبقى كما هي بلا استثناء.
class BackupValidationException implements Exception {
  const BackupValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// فشل تطبيق نسخة **صحيحة** أثناء الكتابة (قيد قاعدة بيانات مثلاً). المعاملة
/// تكون قد تراجعت كاملة، فبيانات المستخدم السابقة كما كانت.
class BackupApplyException implements Exception {
  const BackupApplyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// معلومات النسخة تُعرض للمستخدم قبل التأكيد — تُبنى من التحقق نفسه، فلا
/// تُطلب موافقة على ملف لم يُفحص.
class BackupInfo {
  const BackupInfo({
    required this.version,
    required this.createdAt,
    required this.legacyLessons,
    required this.counts,
    required this.photoCount,
  });

  /// رقم صيغة البيان (1/2/3).
  final int version;

  /// وقت إنشاء النسخة كما كتبه التطبيق المصدِّر (`null` إن غاب/كان تالفاً).
  final DateTime? createdAt;

  /// نسخة بلا جدول حصص: سجلاتها تُرحَّل إلى الحصة الأولى (تعريف الترحيل).
  final bool legacyLessons;

  /// عدد الصفوف في كل قسم من أقسام البيان (مفاتيح ثابتة للعرض).
  final Map<String, int> counts;

  /// عدد الصور المضمّنة في الحاوية.
  final int photoCount;
}

/// نسخة مفكوكة: البيان + صورها الخام مفهرسة باسم المدخل في الحاوية.
class _DecodedBackup {
  const _DecodedBackup(this.manifest, this.photos);

  final Map<String, Object?> manifest;
  final Map<String, List<int>> photos;
}

/// نسخة مُتحقَّق منها وجاهزة للتطبيق: صفوف مُفكَّكة ومُصنَّفة، بلا أي كتابة
/// على قاعدة البيانات. فصل التحقق عن التطبيق هو ما يجعل «الرفض قبل المسح»
/// ممكناً.
class _RestorePlan {
  _RestorePlan({
    required this.version,
    required this.createdAt,
    required this.legacyLessons,
    required this.lessons,
    required this.years,
    required this.classes,
    required this.students,
    required this.badges,
    required this.sessions,
    required this.attendance,
    required this.scanEvents,
    required this.leaves,
    required this.holidays,
    required this.alerts,
    required this.auditLogs,
    required this.settings,
  });

  final int version;
  final DateTime? createdAt;
  final bool legacyLessons;
  final List<Lesson> lessons;
  final List<AcademicYear> years;
  final List<SchoolClass> classes;
  final List<Student> students;
  final List<Badge> badges;
  final List<Session> sessions;
  final List<AttendanceRow> attendance;
  final List<ScanEvent> scanEvents;
  final List<Leave> leaves;
  final List<Holiday> holidays;
  final List<AlertNotification> alerts;
  final List<AuditLog> auditLogs;
  final Map<String, String> settings;

  Map<String, int> get counts => <String, int>{
        'years': years.length,
        'classes': classes.length,
        'students': students.length,
        'lessons': lessons.length,
        'sessions': sessions.length,
        'attendance': attendance.length,
        'leaves': leaves.length,
        'scan_events': scanEvents.length,
        'badges': badges.length,
        'holidays': holidays.length,
        'alerts': alerts.length,
        'audit_logs': auditLogs.length,
      };
}

class BackupService {
  BackupService(
    this.db, {
    PhotoInstaller? photoInstaller,
    PhotoSnapshotter? photoSnapshot,
  })  : _installPhoto = photoInstaller ?? PhotoStore.install,
        _photoSnapshot = photoSnapshot ?? PhotoStore.existingPaths;

  final AppDb db;
  final PhotoInstaller _installPhoto;
  final PhotoSnapshotter _photoSnapshot;

  static const String manifestName = 'backup.json';
  static const String photosPrefix = 'photos/';
  static const int backupVersion = 3;

  /// حارس تنفيذ واحد لكل قاعدة بيانات: نافذة تأكيد مزدوجة أو نقرة مكرّرة لا
  /// تُشغّل استعادتين متداخلتين على القاعدة نفسها.
  static final Expando<bool> _activeRestores = Expando<bool>('backup-restore');

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
        'lessons': _rows(await db.select(db.lessons).get()),
        'alertNotifications': _rows(await db.select(db.alertNotifications).get()),
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

  /// **نقطة أمان قبل الاستبدال**: نسخة كاملة من بيانات الجهاز الحالية تُكتب
  /// في مجلد التطبيق الخاص بلا واجهة مشاركة (تعمل أثناء الاستعادة نفسها).
  /// تُستدعى قبل `restoreFull`؛ فشلها يجب أن يُلغي الاستعادة — لا استبدال
  /// بلا مخرج.
  Future<String> exportSafetyCopy({String reason = 'قبل الاستعادة'}) async {
    final Uint8List bytes = await exportBytes();
    final String name = backupFileName(reason: reason);
    final Directory dir = await getApplicationDocumentsDirectory();
    final File f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes, flush: true);
    await db.logAudit('backup_restore_safety', f.path);
    return f.path;
  }

  /// يفحص النسخة ويعيد معلوماتها بلا أي كتابة: الشكل، الإصدار، الأنواع،
  /// المراجع، وسياسة الحصص. أي خلل ⇒ استثناء (`FormatException` للشكل
  /// والإصدار، [BackupValidationException] للبنية والمراجع).
  ///
  /// تُستدعى من الواجهة قبل عرض التأكيد: لا يُطلب من المستخدم الموافقة على
  /// ملف لم يُتحقق من صلاحيته.
  Future<BackupInfo> inspect(Uint8List bytes) async {
    final _DecodedBackup decoded = _decode(bytes);
    final _RestorePlan plan = _planOf(decoded.manifest);
    return BackupInfo(
      version: plan.version,
      createdAt: plan.createdAt,
      legacyLessons: plan.legacyLessons,
      counts: plan.counts,
      photoCount: decoded.photos.length,
    );
  }

  /// استعادة كاملة: تستبدل بيانات التطبيق الحالية ببيانات النسخة.
  ///
  /// التسلسل: فكّ ← تحقق كامل (بلا كتابة) ← تثبيت الصور ← معاملة واحدة
  /// (مسح كل الجداول + إدراج بيانات النسخة + فحص سلامة المراجع + تدقيق).
  /// أي فشل داخل المعاملة يتراجع كاملاً، فتبقى بيانات المستخدم السابقة.
  ///
  /// يجب استدعاؤها بعد تأكيد صريح من المستخدم، ومع نسخة أمان
  /// ([exportSafetyCopy]) موثوقة. تقبل حاوية zip (الصيغة 2/3) وملف JSON
  /// عادماً (الصيغة 1).
  Future<void> restoreFull(Uint8List bytes) async {
    if (_activeRestores[db] ?? false) {
      throw StateError(
        'عملية استعادة جارية بالفعل — انتظر انتهاءها قبل تكرارها.',
      );
    }
    _activeRestores[db] = true;
    try {
      final _DecodedBackup decoded = _decode(bytes);
      // كل التحقق قبل أول كتابة: نسخة تالفة لا تمسّ البيانات الحالية.
      final _RestorePlan plan = _planOf(decoded.manifest);
      // الصور أولاً خارج المعاملة: معاملة مفتوحة على عمليات ملفات بطيئة
      // أسوأ من تثبيت مسبق. المقابل: فشل لاحق يترك ملفات أنشأتها هذه
      // المحاولة، فتُتتبَّع هنا وتُنظَّف وحدها عند الفشل.
      final Set<String>? existedBefore =
          decoded.photos.isEmpty ? const <String>{} : await _snapshotPhotos();
      final Set<String> created = <String>{};
      final Map<int, String> installed = await _installPhotos(decoded, created);
      try {
        await db.transaction<void>(() async {
          await _clearAll();
          await _insertAll(plan, photoPaths: installed);
          await _verifyRestoredState();
          await db.logAudit(
            'backup_restore_full',
            'version=${plan.version} legacyLessons=${plan.legacyLessons}',
          );
        });
      } on FormatException {
        await _discardCreatedPhotos(created, existedBefore);
        rethrow;
      } on BackupValidationException {
        await _discardCreatedPhotos(created, existedBefore);
        rethrow;
      } on BackupApplyException {
        await _discardCreatedPhotos(created, existedBefore);
        rethrow;
      } catch (e) {
        final String note = await _discardCreatedPhotos(created, existedBefore);
        throw BackupApplyException(
          'تعذر تطبيق النسخة، وأُعيدت بياناتك السابقة كما كانت قبل المحاولة. '
          '($e)$note',
        );
      }
    } finally {
      _activeRestores[db] = false;
    }
  }

  // ---------------- فكّ النسخة ----------------

  /// يفكّ بايتات النسخة: حاوية zip أو JSON عادماً.
  _DecodedBackup _decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('الملف فارغ — اختر ملف نسخة احتياطية صالحاً.');
    }
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
  Future<Map<int, String>> _installPhotos(
    _DecodedBackup decoded,
    Set<String> created,
  ) async {
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
        final String path = await _installPhoto(
          p.basename(e.value),
          decoded.photos[e.value]!,
        );
        installed[e.key] = path;
        // يُسجَّل بعد نجاح التثبيت فقط: عند فشل لاحق تُحذف هذه الملفات
        // وحدها، ولا يُمسّ ملف كان على الجهاز قبل المحاولة.
        created.add(path);
      } catch (_) {
        continue; // صورة حاوية تالفة: تُتخطى ويُكمل الاسترجاع.
      }
    }
    return installed;
  }

  /// مسارات الصور السابقة، أو `null` إذا تعذّرت قراءتها.
  ///
  /// `null` تعني **تعطيل التنظيف**: الحذف بلا معرفة الملفات السابقة قد يمسّ
  /// صورة موجودة، وترك ملفات أنشأتها محاولة فاشلة أهون من حذف صورة المستخدم.
  Future<Set<String>?> _snapshotPhotos() async {
    try {
      return await _photoSnapshot();
    } catch (_) {
      return null;
    }
  }

  /// ملفات الصور التي أنشأتها هذه المحاولة ويجوز حذفها بعد فشلها.
  ///
  /// دالة نقية (بلا قرص) لتكون سياستها قابلة للاختبار وحدها:
  /// 1. لا يُحذف ملف كان موجوداً قبل الاستعادة ([existedBefore]) — حتى لو
  ///    أرجع المُثبِّت مساره.
  /// 2. لا يُحذف ملف يشير إليه سجل طالب في القاعدة بعد التراجع
  ///    ([referencedByRows]) — فقد يكون مشتركاً أو مستخدماً من سجل آخر.
  /// 3. لا يُحذف إلا ما سجّلته العملية نفسها في [created].
  static List<String> photosToDiscard({
    required Iterable<String> created,
    required Set<String> existedBefore,
    required Set<String> referencedByRows,
  }) {
    final Set<String> out = <String>{};
    for (final String path in created) {
      if (path.isEmpty ||
          existedBefore.contains(path) ||
          referencedByRows.contains(path)) {
        continue;
      }
      out.add(path);
    }
    return out.toList(growable: false);
  }

  /// ينظّف ملفات الصور التي أنشأتها محاولة **فاشلة**، ويعيد ملاحظة عربية
  /// تُضاف إلى رسالة الفشل.
  ///
  /// لا يرمي أبداً: سبب فشل الاستعادة هو الخبر المهم، ولا يجوز أن يحجبه
  /// فشل تنظيف ثانوي — يُذكر صراحةً في الملاحظة بدل إخفائه.
  Future<String> _discardCreatedPhotos(
    Set<String> created,
    Set<String>? existedBefore,
  ) async {
    if (created.isEmpty) {
      return '';
    }
    if (existedBefore == null) {
      return ' لم تُنظَّف ملفات الصور التي أنشأتها المحاولة: تعذّرت قراءة '
          'قائمة الصور السابقة، والحذف بلا معرفتها خطر على صورك.';
    }
    try {
      final Set<String> referenced = <String>{
        for (final Student s in await db.select(db.students).get())
          if (s.photoPath != null && s.photoPath!.isNotEmpty) s.photoPath!,
      };
      final List<String> victims = photosToDiscard(
        created: created,
        existedBefore: existedBefore,
        referencedByRows: referenced,
      );
      int removed = 0;
      int failed = 0;
      for (final String path in victims) {
        try {
          await PhotoStore.deleteIfExists(path);
          removed++;
        } catch (_) {
          failed++;
        }
      }
      final String kept = created.length - victims.length;
      final StringBuffer note = StringBuffer()
        ..write(' نُظّف $removed ملف صورة أنشأتها المحاولة');
      if (kept > 0) {
        note.write('، وأُبقي $kept ملفاً لأنه كان موجوداً مسبقاً أو يستخدمه سجل');
      }
      if (failed > 0) {
        note.write('، وتعذّر حذف $failed ملف');
      }
      note.write('.');
      return note.toString();
    } catch (_) {
      return ' تعذّر تنظيف ملفات الصور التي أنشأتها المحاولة؛ '
          'راجع مجلد صور التطبيق إن أردت حذفها يدوياً.';
    }
  }

  // ---------------- التحقق ----------------

  void _assertFormat(Map<String, Object?> data) {
    if (data['format'] != 'student-hodor-backup') {
      throw const FormatException('الملف ليس من تنسيق نسخ هذا النظام');
    }
    // حارس الصيغة: ملف بصيغة أحدث مما يفهمه هذا الإصدار لا يُقرأ «جزئياً».
    // بلا هذا الحارس تُستعاد نسخة مستقبلية (مخطط مختلف) بلا علم المستخدم،
    // فتُفقد الحقول التي لا يعرفها هذا الإصدار بصمت.
    final int version = _versionOf(data['version']);
    if (version < 1) {
      throw FormatException('رقم صيغة النسخة غير صالح ($version).');
    }
    if (version > backupVersion) {
      throw FormatException(
        'هذه النسخة بصيغة أحدث ($version) من التي يدعمها هذا الإصدار '
        '($backupVersion) — حدّث التطبيق قبل استعادتها.',
      );
    }
  }

  /// رقم صيغة البيان؛ النسخ الأقدم من إدراج الحقل تُعدّ صيغة 1.
  static int _versionOf(Object? raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    final int? parsed = int.tryParse('${raw ?? ''}'.trim());
    return parsed ?? 1;
  }

  static DateTime? _createdAtOf(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;

  /// يبني خطة الاستعادة بعد تحقق كامل. لا يكتب شيئاً ولا يفتح معاملة.
  _RestorePlan _planOf(Map<String, Object?> data) {
    _assertFormat(data);
    final int version = _versionOf(data['version']);

    final List<Map<String, Object?>> lessonRows = _rowsOf(data, 'lessons');
    final List<Map<String, Object?>> yearRows = _rowsOf(data, 'years');
    final List<Map<String, Object?>> classRows = _rowsOf(data, 'classes');
    final List<Map<String, Object?>> studentRows = _rowsOf(data, 'students');
    final List<Map<String, Object?>> badgeRows = _rowsOf(data, 'badges');
    final List<Map<String, Object?>> sessionRows = _rowsOf(data, 'sessions');
    final List<Map<String, Object?>> attendanceRows = _rowsOf(data, 'attendance');
    final List<Map<String, Object?>> scanRows = _rowsOf(data, 'scanEvents');
    final List<Map<String, Object?>> leaveRows = _rowsOf(data, 'leaves');
    final List<Map<String, Object?>> holidayRows = _rowsOf(data, 'holidays');
    final List<Map<String, Object?>> alertRows =
        _rowsOf(data, 'alertNotifications');
    final List<Map<String, Object?>> auditRows = _rowsOf(data, 'auditLogs');
    final Map<String, String> settings = _settingsOf(data);

    // جدول حصص موجود ⇒ نسخة حديثة تُفحص مراجعها بصرامة. غيابه ⇒ نسخة قديمة
    // تُرحَّل بالتعريف الرسمي (الحصة الأولى).
    final bool legacyLessons = lessonRows.isEmpty;

    final List<Lesson> lessons =
        _parseRows(lessonRows, 'الحصص', (Map<String, dynamic> r) => Lesson.fromJson(r));
    final List<AcademicYear> years = _parseRows(
      yearRows,
      'السنوات',
      // `closed` جزء من المخطط الأول: لم تُضف بأي هجرة، فكل نسخة حقيقية
      // تحملها. تُعامل كحقل إلزامي ولا يُخترع لها افتراضي.
      (Map<String, dynamic> r) => AcademicYear.fromJson(r),
    );
    final List<SchoolClass> classes = _parseRows(
      classRows,
      'الصفوف',
      (Map<String, dynamic> r) => SchoolClass.fromJson(r),
    );
    final List<Student> students = _parseRows(
      studentRows,
      'الطلاب',
      // عمود الهاتف أُضيف بعد الصيغة 1: الغياب يعني «لا هاتف» لا خطأ.
      (Map<String, dynamic> r) => Student.fromJson(
        _withDefaults(r, <String, Object?>{'phone': null}),
      ),
    );
    final List<Badge> badges = _parseRows(
      badgeRows,
      'البادجات',
      (Map<String, dynamic> r) => Badge.fromJson(r),
    );

    // الجلسات والحضور: مساران لأن سياسة المرجع تختلف بين النسختين.
    final List<Session> sessions = <Session>[];
    for (int i = 0; i < sessionRows.length; i++) {
      final Map<String, Object?> row = sessionRows[i];
      if (legacyLessons) {
        _requireNoLessonRef(row, 'الجلسات', i);
      }
      try {
        sessions.add(
          Session.fromJson(
            legacyLessons
                ? _withDefaults(row, <String, Object?>{'lesson_id': 0})
                : row,
          ),
        );
      } catch (e) {
        throw BackupValidationException(
          'تعذر قراءة السطر ${i + 1} من «الجلسات»: $e',
        );
      }
    }

    final List<AttendanceRow> attendance = <AttendanceRow>[];
    for (int i = 0; i < attendanceRows.length; i++) {
      final Map<String, Object?> row = attendanceRows[i];
      if (legacyLessons) {
        _requireNoLessonRef(row, 'سجلات الحضور', i);
      }
      try {
        attendance.add(
          AttendanceRow.fromJson(
            legacyLessons
                ? _withDefaults(
                    row,
                    <String, Object?>{'lesson_id': 0, 'arrival_time': null},
                  )
                : row,
          ),
        );
      } catch (e) {
        throw BackupValidationException(
          'تعذر قراءة السطر ${i + 1} من «سجلات الحضور»: $e',
        );
      }
    }

    final List<ScanEvent> scanEvents = _parseRows(
      scanRows,
      'أحداث المسح',
      (Map<String, dynamic> r) => ScanEvent.fromJson(r),
    );
    final List<Leave> leaves = _parseRows(
      leaveRows,
      'الإجازات',
      // إجازة قديمة بلا نطاق = كل حصص اليوم (الدلالة الأصلية).
      (Map<String, dynamic> r) => Leave.fromJson(
        _withDefaults(r, <String, Object?>{'from_slot': null, 'to_slot': null}),
      ),
    );
    final List<Holiday> holidays = _parseRows(
      holidayRows,
      'العطل',
      (Map<String, dynamic> r) => Holiday.fromJson(r),
    );
    final List<AlertNotification> alerts = _parseRows(
      alertRows,
      'التنبيهات',
      (Map<String, dynamic> r) => AlertNotification.fromJson(r),
    );
    final List<AuditLog> auditLogs = _parseRows(
      auditRows,
      'سجل التدقيق',
      (Map<String, dynamic> r) => AuditLog.fromJson(r),
    );

    // معرّفات مكرّرة تعني ملفاً تالفاً: تُرفض هنا برسالة واضحة بدل فشل قيد
    // القاعدة في منتصف الاستعادة.
    _requireUniqueIds(<int>[for (final Lesson l in lessons) l.id], 'الحصص');
    _requireUniqueIds(<int>[for (final AcademicYear y in years) y.id], 'السنوات');
    _requireUniqueIds(<int>[for (final SchoolClass c in classes) c.id], 'الصفوف');
    _requireUniqueIds(<int>[for (final Student s in students) s.id], 'الطلاب');
    _requireUniqueIds(<int>[for (final Badge b in badges) b.id], 'البادجات');
    _requireUniqueIds(<int>[for (final Session s in sessions) s.id], 'الجلسات');
    _requireUniqueIds(
      <int>[for (final AttendanceRow r in attendance) r.id],
      'سجلات الحضور',
    );
    _requireUniqueIds(
      <int>[for (final ScanEvent e in scanEvents) e.id],
      'أحداث المسح',
    );
    _requireUniqueIds(<int>[for (final Leave l in leaves) l.id], 'الإجازات');
    _requireUniqueIds(<int>[for (final Holiday h in holidays) h.id], 'العطل');
    _requireUniqueIds(
      <int>[for (final AlertNotification n in alerts) n.id],
      'التنبيهات',
    );
    _requireUniqueIds(<int>[for (final AuditLog l in auditLogs) l.id], 'التدقيق');

    final Set<int> yearIds = <int>{for (final AcademicYear y in years) y.id};
    final Set<int> classIds = <int>{for (final SchoolClass c in classes) c.id};
    final Set<int> studentIds = <int>{for (final Student s in students) s.id};
    final Set<int> lessonIds = <int>{for (final Lesson l in lessons) l.id};

    for (final SchoolClass c in classes) {
      _requireRef(
        c.yearId,
        yearIds,
        'الصف ${c.id} يشير إلى سنة غير موجودة (${c.yearId}) — '
        'النسخة غير متسقة.',
      );
    }
    for (final Student s in students) {
      _requireRef(
        s.yearId,
        yearIds,
        'الطالب ${s.id} يشير إلى سنة غير موجودة (${s.yearId}).',
      );
      _requireRef(
        s.classId,
        classIds,
        'الطالب ${s.id} يشير إلى صف غير موجود (${s.classId}).',
      );
    }
    for (final Badge b in badges) {
      _requireRef(
        b.studentId,
        studentIds,
        'البادج ${b.id} يشير إلى طالب غير موجود (${b.studentId}).',
      );
    }
    for (final Session s in sessions) {
      _requireRef(
        s.yearId,
        yearIds,
        'الجلسة ${s.id} تشير إلى سنة غير موجودة (${s.yearId}).',
      );
      _requireRef(
        s.classId,
        classIds,
        'الجلسة ${s.id} تشير إلى صف غير موجود (${s.classId}).',
      );
      if (!legacyLessons) {
        _requireKnownLesson(s.lessonId, lessonIds, 'الجلسة ${s.id}');
      }
    }
    for (final AttendanceRow r in attendance) {
      _requireRef(
        r.yearId,
        yearIds,
        'سجل الحضور ${r.id} يشير إلى سنة غير موجودة (${r.yearId}).',
      );
      _requireRef(
        r.classId,
        classIds,
        'سجل الحضور ${r.id} يشير إلى صف غير موجود (${r.classId}).',
      );
      _requireRef(
        r.studentId,
        studentIds,
        'سجل الحضور ${r.id} يشير إلى طالب غير موجود (${r.studentId}).',
      );
      if (!legacyLessons) {
        _requireKnownLesson(r.lessonId, lessonIds, 'سجل الحضور ${r.id}');
      }
    }
    for (final Leave l in leaves) {
      _requireRef(
        l.yearId,
        yearIds,
        'الإجازة ${l.id} تشير إلى سنة غير موجودة (${l.yearId}).',
      );
      _requireRef(
        l.studentId,
        studentIds,
        'الإجازة ${l.id} تشير إلى طالب غير موجود (${l.studentId}).',
      );
    }
    for (final AlertNotification n in alerts) {
      _requireRef(
        n.yearId,
        yearIds,
        'التنبيه ${n.id} يشير إلى سنة غير موجودة (${n.yearId}).',
      );
      _requireRef(
        n.studentId,
        studentIds,
        'التنبيه ${n.id} يشير إلى طالب غير موجود (${n.studentId}).',
      );
    }

    return _RestorePlan(
      version: version,
      createdAt: _createdAtOf(data['at']),
      legacyLessons: legacyLessons,
      lessons: lessons,
      years: years,
      classes: classes,
      students: students,
      badges: badges,
      sessions: sessions,
      attendance: attendance,
      scanEvents: scanEvents,
      leaves: leaves,
      holidays: holidays,
      alerts: alerts,
      auditLogs: auditLogs,
      settings: settings,
    );
  }

  /// قائمة صفوف قسم من البيان: الغياب = قسم فارغ، وأي شكل آخر = ملف تالف.
  static List<Map<String, Object?>> _rowsOf(
    Map<String, Object?> data,
    String key,
  ) {
    final Object? raw = data[key];
    if (raw == null) {
      return const <Map<String, Object?>>[];
    }
    if (raw is! List) {
      throw BackupValidationException(
        'حقل «$key» في النسخة ليس قائمة — الملف تالف.',
      );
    }
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
    for (final Object? entry in raw) {
      if (entry is! Map) {
        throw BackupValidationException(
          'حقل «$key» يحوي سطراً ليس كائناً — الملف تالف.',
        );
      }
      rows.add(entry.cast<String, Object?>());
    }
    return rows;
  }

  static Map<String, String> _settingsOf(Map<String, Object?> data) {
    final Object? raw = data['settings'];
    if (raw == null) {
      return const <String, String>{};
    }
    if (raw is! Map) {
      throw const BackupValidationException(
        'حقل «settings» في النسخة ليس خريطة — الملف تالف.',
      );
    }
    final Map<String, String> out = <String, String>{};
    raw.forEach((dynamic key, dynamic value) {
      if (value == null) {
        return;
      }
      out['$key'] = '$value';
    });
    return out;
  }

  static List<T> _parseRows<T>(
    List<Map<String, Object?>> rows,
    String label,
    T Function(Map<String, dynamic> json) parse,
  ) {
    final List<T> out = <T>[];
    for (int i = 0; i < rows.length; i++) {
      try {
        out.add(parse(rows[i]));
      } catch (e) {
        throw BackupValidationException(
          'تعذر قراءة السطر ${i + 1} من «$label»: $e',
        );
      }
    }
    return out;
  }

  static void _requireUniqueIds(Iterable<int> ids, String label) {
    final Set<int> seen = <int>{};
    for (final int id in ids) {
      if (!seen.add(id)) {
        throw BackupValidationException(
          'معرّف مكرر ($id) في «$label» — الملف تالف.',
        );
      }
    }
  }

  static void _requireRef(int value, Set<int> known, String message) {
    if (!known.contains(value)) {
      throw BackupValidationException(message);
    }
  }

  /// سياسة الحصص في النسخ الحديثة: مرجع غير معروف **خلل** لا حالة قديمة.
  static void _requireKnownLesson(int lessonId, Set<int> known, String record) {
    if (known.contains(lessonId)) {
      return;
    }
    throw BackupValidationException(
      '$record يشير إلى حصة غير موجودة ($lessonId) — المرجع المجهول لا يُسند '
      'تلقائياً إلى الحصة الأولى. أصلح النسخة أو استعد نسخة سليمة.',
    );
  }

  /// نسخة بلا جدول حصص لا يجوز أن تحمل مرجع حصة صريحاً: لا يمكن التحقق منه،
  /// وإسقاطه على الحصة الأولى يغيّر معنى السجل.
  static void _requireNoLessonRef(
    Map<String, Object?> row,
    String label,
    int index,
  ) {
    final Object? raw = _rawField(row, 'lesson_id');
    if (raw != null) {
      throw BackupValidationException(
        'السطر ${index + 1} من «$label» يحمل مرجع حصة ($raw) في نسخة بلا جدول '
        'حصص — لا يمكن التحقق من هذا المرجع.',
      );
    }
  }

  /// يدمج قيماً افتراضية في سطر بيان قديم قبل `fromJson`.
  ///
  /// ضرورة توافق: النسخ الأقدم تفتقد أعمدة أُضيفت لاحقاً (`lesson_id`،
  /// `arrival_time`، `phone`، نطاق الإجازة…)، و`fromJson` يتوقع كل الأعمدة.
  /// القيم الافتراضية هي **دلالة** العمود وقت إضافته لا رقم اعتباطي:
  /// السطر القديم = الحصة الأولى (بحسب السياق)، وبلا وقت وصول، وإجازة كل اليوم.
  ///
  /// ويُكتب المفتاح بصيغتيه (`lesson_id` و`lessonId`): صيغة مفاتيح JSON في
  /// هذا الإصدار لا تُفترض، والافتراضي لا يُكتب إن وُجدت قيمة غير فارغة.
  static Map<String, Object?> _withDefaults(
    Map<String, Object?> row,
    Map<String, Object?> defaults,
  ) {
    final Map<String, Object?> out = <String, Object?>{...row};
    for (final MapEntry<String, Object?> e in defaults.entries) {
      if (_rawField(out, e.key) != null) {
        continue; // القيمة موجودة فعلاً: لا تُستبدل.
      }
      out[e.key] = e.value;
      out[_camelKey(e.key)] = e.value;
    }
    return out;
  }

  /// قيمة حقل بأي صيغة كتابة (`lesson_id` أو `lessonId`)، أو `null` إن غاب.
  static Object? _rawField(Map<String, Object?> row, String snakeKey) {
    if (row.containsKey(snakeKey)) {
      return row[snakeKey];
    }
    final String camel = _camelKey(snakeKey);
    return row.containsKey(camel) ? row[camel] : null;
  }

  /// `lesson_id` ⇒ `lessonId` (وأي مفتاح مركّب مثله).
  static String _camelKey(String snake) {
    final List<String> parts = snake.split('_');
    if (parts.length == 1) {
      return snake;
    }
    return parts.first +
        parts
            .skip(1)
            .map(
              (String p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1),
            )
            .join();
  }

  // ---------------- التطبيق ----------------

  /// مسح كل الجداول بترتيب يحترم المفاتيح الأجنبية. يُستدعى **داخل** معاملة
  /// الاستعادة وحدها، فلا توجد حالة تُمسح فيها البيانات بلا إدراج بديل.
  Future<void> _clearAll() async {
    await db.delete(db.scanEvents).go();
    await db.delete(db.attendanceRows).go();
    await db.delete(db.sessions).go();
    await db.delete(db.alertNotifications).go();
    await db.delete(db.leaves).go();
    await db.delete(db.badges).go();
    await db.delete(db.students).go();
    await db.delete(db.schoolClasses).go();
    await db.delete(db.academicYears).go();
    await db.delete(db.holidays).go();
    // الحصص آخر ما يُحذف (السجلات تشير إليها) وأول ما يُدرَج.
    await db.delete(db.lessons).go();
    await db.delete(db.auditLogs).go();
    await db.delete(db.settings).go();
  }

  Future<void> _insertAll(
    _RestorePlan plan, {
    required Map<int, String> photoPaths,
  }) async {
    // 1) الحصص أولاً: الجلسات والسجلات تحمل مفاتيح أجنبية إليها.
    for (final Lesson l in plan.lessons) {
      await db.into(db.lessons).insert(l.toCompanion(false));
    }
    if (plan.lessons.isEmpty) {
      // نسخة قديمة بلا جدول حصص ⇒ الجدول الافتراضي، وكل سطر بلا مرجع
      // يُسند إلى الحصة الأولى (كان اليوم كله حصة واحدة).
      await db.ensureLessonsSeeded();
    }
    final int legacyLessonId =
        plan.legacyLessons ? (await db.firstLesson()).id : 0;

    for (final AcademicYear y in plan.years) {
      await db.into(db.academicYears).insert(y.toCompanion(false));
    }
    for (final SchoolClass c in plan.classes) {
      await db.into(db.schoolClasses).insert(c.toCompanion(false));
    }
    for (final Student s in plan.students) {
      StudentsCompanion c = s.toCompanion(false);
      // مسار الصورة في البيان يخص الجهاز المصدِّر؛ إن جاءت صورته في
      // الحاوية ثُبّتت محلياً وحلّ مسارها الجديد محلّه.
      final String? installed = photoPaths[s.id];
      if (installed != null) {
        c = c.copyWith(photoPath: Value(installed));
      }
      await db.into(db.students).insert(c);
    }
    for (final Badge b in plan.badges) {
      await db.into(db.badges).insert(b.toCompanion(false));
    }
    for (final Session s in plan.sessions) {
      await db.into(db.sessions).insert(
            s.toCompanion(false).copyWith(
                  lessonId:
                      Value(plan.legacyLessons ? legacyLessonId : s.lessonId),
                ),
          );
    }
    for (final AttendanceRow r in plan.attendance) {
      await db.into(db.attendanceRows).insert(
            r.toCompanion(false).copyWith(
                  lessonId:
                      Value(plan.legacyLessons ? legacyLessonId : r.lessonId),
                ),
          );
    }
    for (final ScanEvent e in plan.scanEvents) {
      await db.into(db.scanEvents).insert(e.toCompanion(false));
    }
    for (final Leave l in plan.leaves) {
      await db.into(db.leaves).insert(l.toCompanion(false));
    }
    for (final Holiday h in plan.holidays) {
      await db.into(db.holidays).insert(h.toCompanion(false));
    }
    for (final AlertNotification n in plan.alerts) {
      await db.into(db.alertNotifications).insert(n.toCompanion(false));
    }
    // معرّفات التدقيق تأتي من الملف صراحةً، وقد تكون خطوة زرع الحصص الافتراضي
    // سجّلت سطراً بمفتاح تلقائي يتعارض معها (نسخة بلا `lessons`) — تُمسح أسطر
    // هذه العملية وحدها قبل كتابة تاريخ الملف، ثم يُسجَّل الاسترجاع بعده.
    await db.delete(db.auditLogs).go();
    for (final AuditLog l in plan.auditLogs) {
      await db.into(db.auditLogs).insert(l.toCompanion(false));
    }
    for (final MapEntry<String, String> e in plan.settings.entries) {
      await db.setSetting(e.key, e.value);
    }
  }

  /// فحص ما بعد الإدراج داخل المعاملة نفسها: أي خلل يعني تراجعاً كاملاً بدل
  /// التزام قاعدة نصف مستعادة.
  Future<void> _verifyRestoredState() async {
    final QueryRow fk = await db.customSelect('PRAGMA foreign_keys').getSingle();
    if (fk.data.values.first != 1) {
      throw const BackupApplyException(
        'المفاتيح الأجنبية غير مفعّلة على الاتصال — أُلغيت الاستعادة حمايةً '
        'لبياناتك.',
      );
    }
    final List<QueryRow> violations =
        await db.customSelect('PRAGMA foreign_key_check').get();
    if (violations.isNotEmpty) {
      throw BackupApplyException(
        'النسخة تُنتج ${violations.length} مرجعاً يتيماً — أُلغيت الاستعادة '
        'وأُعيدت بياناتك السابقة.',
      );
    }
    if (await db.lessonCount() == 0) {
      throw const BackupApplyException(
        'لم يبق جدول حصص بعد الاستعادة — أُلغيت العملية وأُعيدت بياناتك '
        'السابقة.',
      );
    }
  }
}
