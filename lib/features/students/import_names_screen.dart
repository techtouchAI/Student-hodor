/// شاشة استيراد أسماء الطلاب من ملف `.txt` أو `.docx` إلى الصف المفتوح.
///
/// التسلسل مفروض: **اختيار ملف ⇒ معاينة كاملة ⇒ تأكيد ⇒ كتابة واحدة**. لا
/// يُكتب شيء قبل التأكيد، والمعاينة تعرض عدد المقبول والمتخطّى وأسباب التخطّي
/// وأول عشرة أسماء كما ستُحفظ تماماً.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/name_import.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../state/providers.dart';

class ImportNamesScreen extends ConsumerStatefulWidget {
  const ImportNamesScreen({
    super.key,
    required this.classId,
    required this.classTitle,
  });

  final int classId;
  final String classTitle;

  @override
  ConsumerState<ImportNamesScreen> createState() => _ImportNamesState();
}

class _ImportNamesState extends ConsumerState<ImportNamesScreen> {
  NameImportPreview? _preview;
  String? _fileName;
  bool _skipExisting = true;
  bool _reading = false;
  bool _writing = false;

  Future<void> _pick() async {
    setState(() => _reading = true);
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['txt', 'docx', 'doc'],
      );
      final String? path = picked.isEmpty ? null : picked.single.path;
      if (path == null) {
        return;
      }
      final Uint8List bytes = await File(path).readAsBytes();
      if (!mounted) {
        return;
      }
      final NameImportPreview preview = parseNameFile(
        fileName: picked.single.name,
        bytes: bytes,
      );
      setState(() {
        _preview = preview;
        _fileName = picked.single.name;
      });
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'students:import');
      if (mounted) {
        _snack('تعذر قراءة الملف: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _reading = false);
      }
    }
  }

  Future<void> _write() async {
    final NameImportPreview? preview = _preview;
    if (preview == null || preview.values.isEmpty) {
      return;
    }
    final int count = preview.values.length;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('تأكيد الاستيراد'),
        content: Text(
          'سيُضاف $count اسماً إلى صف «${widget.classTitle}» بالترتيب الوارد '
          'في الملف${_skipExisting ? '، مع تجاهل الأسماء الموجودة' : ''}.\n\n'
          'لا يُحذف ولا يُعدَّل أي طالب قائم.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('تراجع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('استيراد'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    setState(() => _writing = true);
    try {
      final AppDb db = ref.read(dbProvider);
      final int yearId = (await db.activeYear())?.id ?? 0;
      if (yearId == 0) {
        _snack('لا توجد سنة فعّالة — أنشئها من شاشة السنوات');
        return;
      }
      final StudentImportOutcome outcome = await db.importStudentNames(
        yearId: yearId,
        classId: widget.classId,
        names: preview.values,
        skipExisting: _skipExisting,
      );
      if (!mounted) {
        return;
      }
      _snack(outcome.summary);
      Navigator.of(context).pop(true);
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'students:import:write');
      if (mounted) {
        _snack('تعذر الاستيراد: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _writing = false);
      }
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final NameImportPreview? preview = _preview;
    return Scaffold(
      appBar: AppBar(title: Text('استيراد أسماء — ${widget.classTitle}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('الملف', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text(
                    'يدعم: ‎.txt‎ (UTF-8 أو Windows-1256) و‎.docx‎ '
                    '(فقرات أو جدول). ملف ‎.doc‎ القديم يُحفظ بصيغة أحدث أولاً.',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: _reading || _writing ? null : _pick,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('اختيار ملف'),
                      ),
                      const SizedBox(width: 12),
                      if (_reading)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      if (_fileName != null)
                        Expanded(
                          child: Text(
                            _fileName!,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (preview != null) ...<Widget>[
            const SizedBox(height: 12),
            _previewCard(preview),
          ],
        ],
      ),
    );
  }

  Widget _previewCard(NameImportPreview preview) {
    final ThemeData theme = Theme.of(context);
    final String? error = preview.error;
    if (error != null) {
      return Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(error, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
        ),
      );
    }
    final Map<String, int> reasons = preview.skippedByReason;
    final List<ImportedName> shown =
        preview.names.take(10).toList(growable: false);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('المعاينة', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: <Widget>[
                _stat('المصدر', preview.source),
                _stat('المقبول', '${preview.names.length}'),
                _stat('المتخطّى', '${preview.skipped.length}'),
              ],
            ),
            if (reasons.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('أسباب التخطّي', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final MapEntry<String, int> e in reasons.entries)
                Text('• ${e.key}: ${e.value}'),
            ],
            if (shown.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                'أول ${shown.length} اسماً كما ستُحفظ',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              for (final ImportedName n in shown)
                Text('${n.line}. ${n.name}'),
              if (preview.names.length > shown.length)
                Text('… و${preview.names.length - shown.length} غيرها'),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _skipExisting,
              onChanged: (bool v) => setState(() => _skipExisting = v),
              title: const Text('تجاهل الأسماء الموجودة في الصف'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: _writing || preview.values.isEmpty ? null : _write,
                icon: const Icon(Icons.playlist_add_check),
                label: Text('استيراد ${preview.values.length} اسماً'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
        ],
      );
}
