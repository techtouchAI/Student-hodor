/// حفظ النسخ الاحتياطية في مجلد التنزيلات العام عبر قناة منصة صغيرة
/// مسجلة في `MainActivity` (على غرار [AppLinks]).
///
/// على أندرويد 10+ يكتب عبر `MediaStore.Downloads` داخل
/// «التنزيلات/نسخة احتياطية للغيابات» **بلا أي صلاحية تخزين** ويعيد مساراً
/// ظاهرياً للعرض على المستخدم. على الإصدارات الأقدم أو خارج أندرويد
/// (الاختبارات) يعيد `null` فيعود المنادي إلى مجلد التطبيق الخاص.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';

class BackupDownloadStore {
  const BackupDownloadStore._();

  static const MethodChannel _channel =
      MethodChannel('iq.techtouch.student_hodor.backup');

  /// المجلد الفرعي داخل التنزيلات الذي تُحفظ فيه كل النسخ.
  static const String folderName = 'نسخة احتياطية للغيابات';

  /// يحفظ بايتات النسخة باسمها المميز ويعيد المسار الظاهر للمستخدم،
  /// أو `null` إن تعذر الحفظ العام (نظام قديم/قناة غير متوفرة).
  static Future<String?> save({
    required String fileName,
    required Uint8List bytes,
  }) async {
    try {
      return await _channel.invokeMethod<String>(
        'saveToDownloads',
        <String, Object>{'fileName': fileName, 'bytes': bytes},
      );
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException catch (_) {
      return null;
    }
  }
}
