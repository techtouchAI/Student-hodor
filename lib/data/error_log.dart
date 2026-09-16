/// سجل الأعطال الدائم: يحوّل أي عطل صامت إلى دليل مكتوب يمكن مشاركته.
///
/// قبل هذه الطبقة كان الاستثناء في وضع Release يُبتلع (ودجت الخطأ يُرسم فارغاً)
/// فيرى المستخدم «شاشة بيضاء» ولا يصلنا أي سبب. الآن كل عطل يُسجَّل في
/// `documents/error_log.txt` (آخر [maxEntries] عطلاً) ويُعرض في شاشة التشخيص.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// سطر سجل واحد: الوقت + الموضع + الرسالة + أهم أسطر التتبع.
class ErrorLogEntry {
  const ErrorLogEntry({
    required this.at,
    required this.where,
    required this.error,
    required this.stack,
  });

  /// يعيد بناء السطر من صيغته المخزّنة، أو null إن كان تالفاً.
  static ErrorLogEntry? parse(String line) {
    final List<String> parts = line.split('|');
    if (parts.length < 4) {
      return null;
    }
    final int? ms = int.tryParse(parts[0]);
    if (ms == null) {
      return null;
    }
    return ErrorLogEntry(
      at: DateTime.fromMillisecondsSinceEpoch(ms),
      where: parts[1],
      error: parts[2],
      stack: parts.sublist(3).join('|'),
    );
  }

  final DateTime at;
  final String where;
  final String error;
  final String stack;

  /// صيغة تخزين سطرية آمنة: لا أسطر جديدة ولا فواصل `|` داخل الحقول.
  String toLine() =>
      '${at.millisecondsSinceEpoch}|$where|${_flat(error)}|${_flat(stack)}';

  static String _flat(String s) =>
      s.replaceAll('\n', ' ↵ ').replaceAll('|', '/');

  @override
  String toString() {
    final List<String> lines = stack
        .split('\n')
        .where((String l) => l.trim().isNotEmpty)
        .take(6)
        .toList();
    return '${_two(at.year)}-${_two(at.month)}-${_two(at.day)} '
        '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}\n'
        'الموضع: $where\nالخطأ: $error\n${lines.join('\n')}';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// سجل الأعطال: نسخة في الذاكرة (فورية) + نسخة ملف (تبقى بعد إغلاق التطبيق).
class AppErrorLog {
  AppErrorLog._();

  static final AppErrorLog instance = AppErrorLog._();

  /// عدد الأسطر المحتفظ بها في الملف.
  static const int maxEntries = 60;
  static const String fileName = 'error_log.txt';

  final List<ErrorLogEntry> _entries = <ErrorLogEntry>[];
  bool _loaded = false;
  bool _loading = false;

  /// نسخة للقراءة فقط من أحدث الأعطال (الأحدث أولاً).
  List<ErrorLogEntry> get entries => List<ErrorLogEntry>.unmodifiable(
        _entries.reversed,
      );

  bool get isEmpty => _entries.isEmpty;

  /// يسجّل عطلاً. آمن تماماً: أي فشل داخله يُبتلع لأن بديلَه الصمتُ.
  void record(Object error, StackTrace stack, {String where = 'unknown'}) {
    try {
      _entries.add(
        ErrorLogEntry(
          at: DateTime.now(),
          where: where,
          error: error.toString(),
          stack: stack.toString(),
        ),
      );
      while (_entries.length > maxEntries) {
        _entries.removeAt(0);
      }
      // كتابة الملف لا تُنتظر: `_flush` تلتقط كل أخطائها داخلياً.
      // ignore: unawaited_futures
      _flush();
    } catch (_) {
      // لا نضيف عطلاً فوق عطل.
    }
  }

  Future<void> _flush() async {
    try {
      final File f = await _file();
      final String body =
          _entries.map((ErrorLogEntry e) => e.toLine()).join('\n');
      await f.writeAsString('$body\n');
    } catch (_) {
      // تعذر الكتابة (مسار/صلاحية) — النسخة في الذاكرة تكفي للعرض.
    }
  }

  /// يحمّل السجل المحفوظ مرة واحدة (يُستدعى عند فتح شاشة التشخيص).
  Future<void> load() async {
    if (_loaded || _loading) {
      return;
    }
    _loading = true;
    try {
      final File f = await _file();
      if (await f.exists()) {
        final List<String> lines = await f.readAsLines();
        for (final String line in lines) {
          final ErrorLogEntry? e = ErrorLogEntry.parse(line);
          if (e != null) {
            _entries.add(e);
          }
        }
        while (_entries.length > maxEntries) {
          _entries.removeAt(0);
        }
      }
      _loaded = true;
    } catch (_) {
      // ملف تالف/مفقود: نبدأ سجلًا نظيفاً.
    } finally {
      _loading = false;
    }
  }

  Future<void> clear() async {
    _entries.clear();
    _loaded = true;
    try {
      final File f = await _file();
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // لا شيء لحذفه.
    }
  }

  Future<File> _file() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, fileName));
  }

  /// تقرير نصي كامل (للمشاركة/النسخ) يتضمن رأساً بتشغيل التطبيق.
  String formatReport({String version = '', String device = ''}) {
    final StringBuffer b = StringBuffer();
    b.writeln('تقرير أعطال «حضور الطالب»');
    if (version.isNotEmpty) {
      b.writeln('الإصدار: $version');
    }
    if (device.isNotEmpty) {
      b.writeln('الجهاز: $device');
    }
    b.writeln('التاريخ: ${DateTime.now().toIso8601String()}');
    b.writeln('عدد الأعطال المسجلة: ${_entries.length}');
    b.writeln('-----------------------------------------');
    if (_entries.isEmpty) {
      b.writeln('لا أعطال مسجلة.');
    }
    for (final ErrorLogEntry e in _entries.reversed) {
      b.writeln(e.toString());
      b.writeln('-----------------------------------------');
    }
    return b.toString();
  }
}
