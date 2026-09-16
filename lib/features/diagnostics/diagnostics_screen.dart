/// التشخيص: إصدار التطبيق، صحة قاعدة البيانات، وسجل الأعطال الكامل.
///
/// هذه الشاشة هي «الصندوق الأسود»: بدل أن يصف المستخدم عطلاً بأنه «شاشة بيضاء»،
/// يرسل نصاً حرفياً يحدد الشاشة والسبب.
library;

import 'package:drift/drift.dart' hide Column, Table;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_info.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../state/providers.dart';

class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsState();
}

class _DiagnosticsState extends ConsumerState<DiagnosticsScreen> {
  bool _loading = true;
  String? _loadError;
  Map<String, int> _counts = <String, int>{};
  String _yearSummary = '-';
  List<ErrorLogEntry> _entries = <ErrorLogEntry>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final AppDb db = ref.read(dbProvider);
      await AppErrorLog.instance.load();
      final Map<String, int> counts = <String, int>{
        'السنوات': await _countRows(db, 'academic_years'),
        'الصفوف': await _countRows(db, 'school_classes'),
        'الطلاب': await _countRows(db, 'students'),
        'البادجات': await _countRows(db, 'badges'),
        'الجلسات': await _countRows(db, 'sessions'),
        'سجلات الحضور': await _countRows(db, 'attendance_rows'),
        'الإجازات': await _countRows(db, 'leaves'),
        'العطل': await _countRows(db, 'holidays'),
      };
      final AcademicYear? y = await db.activeYear();
      if (!mounted) {
        return;
      }
      setState(() {
        _counts = counts;
        _yearSummary = y == null
            ? 'لا توجد سنة فعّالة'
            : '${y.name} (${y.start} → ${y.end})'
                '${y.closed ? ' — مقفلة' : ''}';
        _entries = AppErrorLog.instance.entries;
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      AppErrorLog.instance.record(e, StackTrace.current, where: 'diagnostics');
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '$e';
        });
      }
    }
  }

  /// عدّ صفوف جدول في SQL مباشرة (بلا تحميل الجدول في الذاكرة، وبلا تمرير
  /// نوع جدول عام يتعارض اسمياً مع ودجات Flutter).
  static Future<int> _countRows(AppDb db, String tableName) async {
    final QueryRow row = await db
        .customSelect('SELECT COUNT(*) AS c FROM $tableName')
        .getSingle();
    return row.read<int>('c');
  }

  Future<void> _copyReport() async {
    final AppDb db = ref.read(dbProvider);
    final String report = AppErrorLog.instance.formatReport(
      version: '${AppInfo.version} (مخطط ${db.schemaVersion})',
    );
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('نُسخ التقرير كاملاً — الصقه في المحادثة')),
      );
    }
  }

  Future<void> _clearLog() async {
    await AppErrorLog.instance.clear();
    if (mounted) {
      setState(() => _entries = <ErrorLogEntry>[]);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('مُسح سجل الأعطال')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('التشخيص وسجل الأعطال')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'التطبيق',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        const Text('الإصدار: ${AppInfo.version}'),
                        Text('إصدار مخطط القاعدة: ${db.schemaVersion}'),
                        Text('السنة الفعّالة: $_yearSummary'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'البيانات',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        for (final MapEntry<String, int> e in _counts.entries)
                          Text('${e.key}: ${e.value}'),
                        if (_loadError != null)
                          Text(
                            'خطأ في القراءة: $_loadError',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'سجل الأعطال (${_entries.length})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'تحديث',
                      onPressed: () {
                        setState(() => _loading = true);
                        _load();
                      },
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: 'نسخ التقرير',
                      onPressed: _copyReport,
                      icon: const Icon(Icons.copy_all),
                    ),
                    IconButton(
                      tooltip: 'مسح السجل',
                      onPressed: _entries.isEmpty ? null : _clearLog,
                      icon: const Icon(Icons.delete_sweep),
                    ),
                  ],
                ),
                if (_entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'لا أعطال مسجلة. إن ظهرت شاشة بيضاء/فارغة، '
                      'أعد فتحها ثم اضغط «تحديث» هنا.',
                    ),
                  )
                else
                  for (final ErrorLogEntry e in _entries)
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: SelectableText(
                          e.toString(),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}
