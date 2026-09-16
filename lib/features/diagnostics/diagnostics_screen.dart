/// التشخيص: إصدار التطبيق، صحة قاعدة البيانات، وسجل الأعطال الكامل.
///
/// هذه الشاشة هي «الصندوق الأسود»: بدل أن يصف المستخدم عطلاً بأنه «شاشة بيضاء»،
/// يرسل نصاً حرفياً يحدد الشاشة والسبب.
library;

import 'package:drift/drift.dart';
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
        'السنوات': await _countAll(db, db.academicYears),
        'الصفوف': await _countAll(db, db.schoolClasses),
        'الطلاب': await _countAll(db, db.students),
        'البادجات': await _countAll(db, db.badges),
        'الجلسات': await _countAll(db, db.sessions),
        'سجلات الحضور': await _countAll(db, db.attendanceRows),
        'الإجازات': await _countAll(db, db.leaves),
        'العطل': await _countAll(db, db.holidays),
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

  static Future<int> _countAll(AppDb db, GeneratedTable table) async {
    final Expression<int> total = countAll();
    final QueryRow? row =
        await (db.selectOnly(table)..addColumns(<Expression<int>>[total]))
            .getSingleOrNull();
    return row?.read(total) ?? 0;
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
                        Text('الإصدار: ${AppInfo.version}'),
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
