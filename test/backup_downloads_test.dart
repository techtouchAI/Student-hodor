/// اسم النسخة الاحتياطية المميز (السبب + التاريخ + الوقت) وسلوك مخزن
/// التنزيلات الآمن بلا قناة منصة (يعيد null فيُستخدم مجلد التطبيق).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/backup_download_store.dart';
import 'package:student_hodor/data/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('اسم النسخة المميز', () {
    test('يحمل السبب والتاريخ والوقت بصيغة ثابتة', () {
      final String name = BackupService.backupFileName(
        reason: 'حذف السنة 2026-2027',
        stamp: DateTime(2026, 9, 18, 10, 30, 5),
      );
      expect(
        name,
        'نسخة احتياطية - حذف السنة 2026-2027 - 2026-09-18 - 10-30-05.zip',
      );
      expect(name, endsWith('.zip'));
    });

    test('بلا محارف ممنوعة في أسماء الملفات ولو جاء السبب بها', () {
      final String name = BackupService.backupFileName(
        reason: 'تصفير/شامل: كامل؟',
        stamp: DateTime(2026, 9, 18, 1, 2, 3),
      );
      expect(
        RegExp(r'[\\/:*?"<>|\r\n\t]').hasMatch(name),
        isFalse,
        reason: 'اسم يصل لنظام الملفات يجب أن يكون آمناً',
      );
      expect(name, startsWith('نسخة احتياطية - '));
      expect(name, contains('2026-09-18'));
    });
  });

  test('مخزن التنزيلات يعيد null بلا قناة منصة فيُستخدم المسار البديل', () async {
    final String? path = await BackupDownloadStore.save(
      fileName: 'اختبار.zip',
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    expect(path, isNull);
  });
}
