/// شاشة التصدير: Excel/PDF، اختيار صفوف وأشهر السنة الدراسية (أو الكل)،
/// خيارات محتوى (تفاصيل يومية/ملخص/إجازات)، ثم مشاركة/طباعة.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/reports_service.dart';
import '../../state/providers.dart';
import 'excel_builder.dart';
import 'pdf_report.dart';

enum ExportFormat { excel, pdf }

/// هل اختار المستخدم قسماً واحداً على الأقل من محتوى الملف؟
/// (ورقة الإجازات خاصة بإكسل). تصدير PDF بلا أي قسم كان يبني مستنداً
/// بلا صفحات فيفشل لحظة الطباعة بخطأ غامض بدل رسالة واضحة.
bool exportHasContent({
  required ExportFormat format,
  required bool daily,
  required bool summary,
  required bool leaves,
}) =>
    daily || summary || (format == ExportFormat.excel && leaves);

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportState();
}

class _ExportState extends ConsumerState<ExportScreen> {
  ExportFormat _format = ExportFormat.excel;
  final Set<int> _classIds = <int>{};
  final Set<String> _monthKeys = <String>{};
  bool _allMonths = false;
  bool _includeDaily = true;
  bool _includeSummary = true;
  bool _includeLeaves = true;
  bool _busy = false;

  List<MonthKey> _monthsOf(AcademicYear year) =>
      SchoolTime.monthsBetweenKeys(year.start, year.end);

  Future<void> _generate() async {
    setState(() => _busy = true);
    try {
      final AppDb db = ref.read(dbProvider);
      final AcademicYear? year = await db.activeYear();
      if (year == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('لا توجد سنة فعّالة للتصدير')),
          );
        }
        return;
      }
      final Map<String, String> settings = await db.effectiveSettings();
      final Set<int> weekdays = <int>{
        for (final String w in (settings['work_weekdays'] ?? '7,1,2,3,4').split(','))
          int.tryParse(w) ?? 0,
      };
      final Set<String> holidays = <String>{
        for (final Holiday h in await db.select(db.holidays).get()) h.date,
      };
      final List<SchoolClass> allClasses =
          await (db.select(db.schoolClasses)..where((c) => c.yearId.equals(year.id)))
              .get();
      final List<SchoolClass> chosen = _classIds.isEmpty
          ? allClasses
          : allClasses.where((SchoolClass c) => _classIds.contains(c.id)).toList();
      if (chosen.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('لا صفوف للتصدير — أضف صفوفاً أولاً')),
          );
        }
        return;
      }
      final List<ExportScopeClass> scope = <ExportScopeClass>[];
      for (final SchoolClass c in chosen) {
        final List<Student> students = await (db.select(db.students)
              ..where((s) => s.classId.equals(c.id))
              ..orderBy(<OrderClauseGenerator<Students>>[
                (Students s) => OrderingTerm.asc(s.fullName),
              ]))
            .get();
        scope.add(ExportScopeClass(c, students));
      }
      final List<MonthKey> months = _allMonths
          ? _monthsOf(year)
          : <MonthKey>[
              for (final MonthKey m in _monthsOf(year))
                if (_monthKeys.contains(m.key)) m,
            ];
      if (months.isEmpty && _includeDaily) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('اختر شهراً واحداً على الأقل')),
          );
        }
        return;
      }
      if (!exportHasContent(
        format: _format,
        daily: _includeDaily,
        summary: _includeSummary,
        leaves: _includeLeaves,
      )) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('اختر قسماً واحداً على الأقل من محتوى الملف'),
            ),
          );
        }
        return;
      }
      if (_format == ExportFormat.excel) {
        final ExcelBuilder builder = ExcelBuilder(
          db: db,
          reports: ReportsService(db),
          schoolName: settings['school_name'] ?? '',
          directorName: settings['director_name'] ?? '',
          year: year,
          months: months,
          classes: scope,
          workWeekdays: weekdays,
          holidayKeys: holidays,
          includeDaily: _includeDaily,
          includeSummary: _includeSummary,
          includeLeaves: _includeLeaves,
        );
        final List<int> bytes = await builder.build();
        final Directory tmp = Directory.systemTemp;
        // اسم الملف عربي واضح («كشف الحضور والغياب - المدرسة - السنة - الشهر»)
        // بدل `hodor-<طابع زمني>.xlsx` اللاتيني الذي يصل للمستلم بلا معنى.
        final String fileName = ExcelBuilder.exportFileName(
          schoolName: settings['school_name'] ?? '',
          yearName: year.name,
          months: months,
        );
        final File f = File('${tmp.path}/$fileName');
        await f.writeAsBytes(bytes);
        await SharePlus.instance.share(
          ShareParams(files: <XFile>[XFile(f.path)]),
        );
      } else {
        final pw.Font regular =
            pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Regular.ttf'));
        final pw.Font bold =
            pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Bold.ttf'));
        final PdfReport report = PdfReport(
          db: db,
          reports: ReportsService(db),
          schoolName: settings['school_name'] ?? '',
          directorName: settings['director_name'] ?? '',
          year: year,
          months: months,
          classes: scope,
          workWeekdays: weekdays,
          holidayKeys: holidays,
          font: regular,
          fontBold: bold,
          includeDaily: _includeDaily,
          includeSummary: _includeSummary,
        );
        await report.layout();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر التصدير: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('تصدير التقارير')),
      body: StreamBuilder<AcademicYear?>(
        stream: db.watchActiveYear(),
        builder: (BuildContext context, AsyncSnapshot<AcademicYear?> ys) {
          final AcademicYear? year = ys.data;
          if (year == null) {
            return const Center(child: Text('لا سنة فعّالة'));
          }
          final List<MonthKey> yearMonths = _monthsOf(year);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              SegmentedButton<ExportFormat>(
                segments: const <ButtonSegment<ExportFormat>>[
                  ButtonSegment<ExportFormat>(
                    value: ExportFormat.excel,
                    label: Text('Excel'),
                    icon: Icon(Icons.grid_on),
                  ),
                  ButtonSegment<ExportFormat>(
                    value: ExportFormat.pdf,
                    label: Text('PDF'),
                    icon: Icon(Icons.picture_as_pdf),
                  ),
                ],
                selected: <ExportFormat>{_format},
                onSelectionChanged: (Set<ExportFormat> s) =>
                    setState(() => _format = s.first),
              ),
              const SizedBox(height: 12),
              const Text('الصفوف (اترك الكل فارغاً لتصدير كل الصفوف):'),
              StreamBuilder<List<SchoolClass>>(
                stream: (db.select(db.schoolClasses)
                      ..where((c) => c.yearId.equals(year.id)))
                    .watch(),
                builder:
                    (BuildContext context, AsyncSnapshot<List<SchoolClass>> snap) =>
                        Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final SchoolClass c in snap.data ?? <SchoolClass>[])
                      FilterChip(
                        label: Text('${c.grade} ـ ${c.section}'),
                        selected: _classIds.contains(c.id),
                        onSelected: (bool v) => setState(() {
                          if (v) {
                            _classIds.add(c.id);
                          } else {
                            _classIds.remove(c.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                value: _allMonths,
                title: const Text('كل أشهر السنة الدراسية'),
                onChanged: (bool v) => setState(() => _allMonths = v),
              ),
              if (!_allMonths)
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final MonthKey m in yearMonths)
                      FilterChip(
                        label: Text(m.label),
                        selected: _monthKeys.contains(m.key),
                        onSelected: (bool v) => setState(() {
                          if (v) {
                            _monthKeys.add(m.key);
                          } else {
                            _monthKeys.remove(m.key);
                          }
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              const Text('محتوى الملف:'),
              SwitchListTile(
                value: _includeDaily,
                title: const Text('جداول الأيام الملوّنة (شهرياً)'),
                onChanged: (bool v) => setState(() => _includeDaily = v),
              ),
              SwitchListTile(
                value: _includeSummary,
                title: const Text('ملخّص السنة لكل طالب'),
                onChanged: (bool v) => setState(() => _includeSummary = v),
              ),
              if (_format == ExportFormat.excel)
                SwitchListTile(
                  value: _includeLeaves,
                  title: const Text('ورقة الإجازات'),
                  onChanged: (bool v) => setState(() => _includeLeaves = v),
                ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy || (!includeAnything) ? null : _generate,
                icon: const Icon(Icons.download),
                label: Text(_busy ? 'جارٍ التوليد…' : 'توليد ومشاركة'),
              ),
            ],
          );
        },
      ),
    );
  }

  bool get includeAnything =>
      _includeDaily ||
      _includeSummary ||
      (_format == ExportFormat.excel && _includeLeaves);
}
