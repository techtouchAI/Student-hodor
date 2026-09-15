/// تقرير PDF شهري ملوّن مطابق لمنطق الإكسل، بعربية مشكّلة صحيحة.
/// الخلية الملوّنة = حالة اليوم (أخضر/أحمر/أصفر/برتقالي/رمادي عطلة).
library;

import 'package:drift/drift.dart' hide Column;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/arabic_shaping.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/reports_service.dart';
import 'excel_builder.dart';

class PdfReport {
  PdfReport({
    required this.db,
    required this.reports,
    required this.schoolName,
    required this.directorName,
    required this.year,
    required this.months,
    required this.classes,
    required this.workWeekdays,
    required this.holidayKeys,
    required this.font,
    required this.fontBold,
    this.includeDaily = true,
    this.includeSummary = true,
  });

  final AppDb db;
  final ReportsService reports;
  final String schoolName;
  final String directorName;
  final AcademicYear year;
  final List<MonthKey> months;
  final List<ExportScopeClass> classes;
  final Set<int> workWeekdays;
  final Set<String> holidayKeys;
  final pw.Font font;
  final pw.Font fontBold;
  final bool includeDaily;
  final bool includeSummary;

  static const double _dayW = 5.2;

  pw.TextStyle _s(double size, {bool bold = false, PdfColor? color}) =>
      pw.TextStyle(font: bold ? fontBold : font, fontSize: size, color: color);

  static String _t(String s) => arabicForPdf(s);

  PdfColor _colorFor(int? status, bool schoolDay) {
    if (!schoolDay) {
      return const PdfColor.fromInt(0xFFD9D9D9);
    }
    switch (status) {
      case AttendanceStatus.present:
        return const PdfColor.fromInt(0xFFC6EFCE);
      case AttendanceStatus.absent:
        return const PdfColor.fromInt(0xFFFFC7CE);
      case AttendanceStatus.leave:
        return const PdfColor.fromInt(0xFFFFEB9C);
      case AttendanceStatus.late:
        return const PdfColor.fromInt(0xFFFCD5B4);
      default:
        return PdfColors.white;
    }
  }

  Map<int, pw.TableColumnWidth> _widths() => <int, pw.TableColumnWidth>{
        0: const pw.FlexColumnWidth(6),
        for (int i = 1; i <= 31; i++) i: const pw.FixedColumnWidth(_dayW),
        32: const pw.FixedColumnWidth(14),
        33: const pw.FixedColumnWidth(14),
        34: const pw.FixedColumnWidth(16),
      };

  pw.TableRow _headerRow(MonthKey m) => pw.TableRow(
        children: <pw.Widget>[
          pw.Text(_t('اسم الطالب'), style: _s(6.5, bold: true)),
          for (int day = 1; day <= 31; day++)
            pw.Container(
              width: _dayW,
              height: 10,
              color: m.isValidDay(day) ? PdfColors.teal800 : PdfColors.white,
              child: pw.Center(
                child: pw.Text(
                  m.isValidDay(day) ? '$day' : '',
                  style: _s(4, bold: true, color: PdfColors.white),
                ),
              ),
            ),
          pw.Text(_t('غياب'), style: _s(5.5, bold: true)),
          pw.Text(_t('إجازة'), style: _s(5.5, bold: true)),
          pw.Text(_t('نسبة'), style: _s(5.5, bold: true)),
        ],
      );

  Future<pw.Document> build() async {
    final pw.Document doc = pw.Document(
      title: 'تقارير الحضور',
      theme: pw.ThemeData.withFont(base: font, bold: fontBold),
    );
    if (includeDaily) {
      for (final MonthKey m in months) {
        for (final ExportScopeClass sc in classes) {
          final List<pw.TableRow> rows = <pw.TableRow>[_headerRow(m)];
          for (final Student s in sc.students) {
            final Map<String, int> byDate = <String, int>{
              for (final AttendanceRow r in await (db.select(db.attendanceRows)
                    ..where(
                      (a) => a.studentId.equals(s.id) & a.yearId.equals(year.id),
                    ))
                  .get())
                r.date: r.status,
            };
            int absent = 0;
            int leave = 0;
            int present = 0;
            int late = 0;
            final List<pw.Widget> cells = <pw.Widget>[
              pw.Text(_t(s.fullName), style: _s(6)),
            ];
            for (int day = 1; day <= 31; day++) {
              if (!m.isValidDay(day)) {
                cells.add(pw.SizedBox(width: _dayW, height: 9));
                continue;
              }
              final DateTime d = DateTime(m.year, m.month, day);
              final int? status = byDate[SchoolTime.dateKey(d)];
              final bool schoolDay = SchoolTime.isSchoolDay(
                d,
                workWeekdays: workWeekdays,
                holidayKeys: holidayKeys,
              );
              switch (status) {
                case AttendanceStatus.absent:
                  absent++;
                case AttendanceStatus.leave:
                  leave++;
                case AttendanceStatus.present:
                  present++;
                case AttendanceStatus.late:
                  late++;
              }
              cells.add(
                pw.Container(
                  width: _dayW,
                  height: 9,
                  color: _colorFor(status, schoolDay),
                ),
              );
            }
            final int recorded = present + absent + leave + late;
            cells.add(pw.Text('$absent', style: _s(6)));
            cells.add(pw.Text('$leave', style: _s(6)));
            cells.add(
              pw.Text(
                '${(recorded == 0 ? 100 : (present + late) * 100 / recorded).toStringAsFixed(0)}%',
                style: _s(6),
              ),
            );
            rows.add(pw.TableRow(children: cells));
          }
          doc.addPage(
            pw.MultiPage(
              pageFormat: PdfPageFormat.a4.landscape,
              header: (pw.Context c) => pw.Column(
                children: <pw.Widget>[
                  pw.Text(
                    _t('$schoolName — ${sc.cls.grade} ـ ${sc.cls.section} — ${m.label}'),
                    style: _s(11, bold: true),
                  ),
                  pw.Text(
                    _t('المدير: $directorName — أخضر حاضر، أحمر غائب، أصفر إجازة، '
                        'برتقالي متأخر، رمادي عطلة'),
                    style: _s(6.5),
                  ),
                  pw.SizedBox(height: 4),
                ],
              ),
              build: (pw.Context c) => <pw.Widget>[
                pw.Table(columnWidths: _widths(), children: rows),
              ],
            ),
          );
        }
      }
    }
    if (includeSummary) {
      await _addSummary(doc);
    }
    return doc;
  }

  Future<void> _addSummary(pw.Document doc) async {
    for (final ExportScopeClass sc in classes) {
      final List<pw.TableRow> rows = <pw.TableRow>[
        pw.TableRow(
          children: <pw.Widget>[
            pw.Text(_t('الاسم'), style: _s(7, bold: true)),
            pw.Text(_t('حضور'), style: _s(7, bold: true)),
            pw.Text(_t('متأخر'), style: _s(7, bold: true)),
            pw.Text(_t('غياب'), style: _s(7, bold: true)),
            pw.Text(_t('إجازة'), style: _s(7, bold: true)),
            pw.Text(_t('النسبة'), style: _s(7, bold: true)),
          ],
        ),
      ];
      for (final Student s in sc.students) {
        final StatusTotals t = await reports.totalsForStudent(s.id, year.id);
        rows.add(
          pw.TableRow(
            children: <pw.Widget>[
              pw.Text(_t(s.fullName), style: _s(6.5)),
              pw.Text('${t.present}', style: _s(6.5)),
              pw.Text('${t.late}', style: _s(6.5)),
              pw.Text('${t.absent}', style: _s(6.5)),
              pw.Text('${t.leave}', style: _s(6.5)),
              pw.Text('${t.ratePct.toStringAsFixed(1)}%', style: _s(6.5)),
            ],
          ),
        );
      }
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          header: (pw.Context c) => pw.Text(
            _t('$schoolName — ملخص السنة — ${sc.cls.grade} ـ ${sc.cls.section}'),
            style: _s(11, bold: true),
          ),
          build: (pw.Context c) => <pw.Widget>[
            pw.Table(
              columnWidths: <int, pw.TableColumnWidth>{
                0: const pw.FlexColumnWidth(5),
                for (int i = 1; i <= 5; i++) i: const pw.FlexColumnWidth(1),
              },
              border: pw.TableBorder.all(width: 0.4),
              children: rows,
            ),
          ],
        ),
      );
    }
  }

  Future<void> layout() async {
    final pw.Document doc = await build();
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: 'attendance-report.pdf',
    );
  }
}
