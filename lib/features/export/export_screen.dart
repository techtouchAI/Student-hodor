/// شاشة التصدير: Excel/PDF، اختيار صفوف وأشهر (أو الكل)، ثم مشاركة/طباعة.
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

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportState();
}

class _ExportState extends ConsumerState<ExportScreen> {
  ExportFormat _format = ExportFormat.excel;
  final Set<int> _classIds = <int>{};
  final Set<int> _months = <int>{};
  bool _allMonths = false;
  bool _busy = false;

  Future<void> _generate() async {
    setState(() => _busy = true);
    try {
      final AppDb db = ref.read(dbProvider);
      final AcademicYear? year = await db.activeYear();
      if (year == null) {
        return;
      }
      final Map<String, String> settings = await db.allSettings();
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
      final List<int> months = _allMonths
          ? _monthsOf(year)
          : (_months.isEmpty ? <int>[DateTime.now().month] : _months.toList()..sort());
      final int yearNumber = int.tryParse(year.start.substring(0, 4)) ?? DateTime.now().year;
      if (_format == ExportFormat.excel) {
        final ExcelBuilder builder = ExcelBuilder(
          db: db,
          reports: ReportsService(db),
          schoolName: settings['school_name'] ?? '',
          directorName: settings['director_name'] ?? '',
          year: year,
          yearNumber: yearNumber,
          months: months,
          classes: scope,
          workWeekdays: weekdays,
          holidayKeys: holidays,
        );
        final List<int> bytes = await builder.build();
        final Directory tmp = Directory.systemTemp;
        final File f = File(
          '${tmp.path}/hodor-${DateTime.now().millisecondsSinceEpoch}.xlsx',
        );
        await f.writeAsBytes(bytes);
        await SharePlus.instance.share(
          ShareParams(files: <XFile>[XFile(f.path)]),
        );
      } else {
        final pw.Font regular =
            pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Regular.ttf'));
        final pw.Font bold =
            pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Bold.ttf'));
        final PdfReport report = PdfReport(
          db: db,
          reports: ReportsService(db),
          schoolName: settings['school_name'] ?? '',
          directorName: settings['director_name'] ?? '',
          year: year,
          yearNumber: yearNumber,
          months: months,
          classes: scope,
          workWeekdays: weekdays,
          holidayKeys: holidays,
          font: regular,
          fontBold: bold,
        );
        await report.layout();
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  List<int> _monthsOf(AcademicYear year) {
    final DateTime s = SchoolTime.parseKey(year.start);
    final DateTime e = SchoolTime.parseKey(year.end);
    final List<int> out = <int>[];
    DateTime d = DateTime(s.year, s.month);
    while (!d.isAfter(DateTime(e.year, e.month))) {
      if (!out.contains(d.month)) {
        out.add(d.month);
      }
      d = DateTime(d.year, d.month + 1);
    }
    return out;
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
                    for (int m = 1; m <= 12; m++)
                      FilterChip(
                        label: Text(SchoolTime.monthNames[m - 1]),
                        selected: _months.contains(m),
                        onSelected: (bool v) => setState(() {
                          if (v) {
                            _months.add(m);
                          } else {
                            _months.remove(m);
                          }
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy ? null : _generate,
                icon: const Icon(Icons.download),
                label: Text(_busy ? 'جارٍ التوليد…' : 'توليد ومشاركة'),
              ),
            ],
          );
        },
      ),
    );
  }
}
