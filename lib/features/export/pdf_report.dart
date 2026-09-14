/// تقرير PDF شهري ملوّن مطابق لمنطق الإكسل، بعربية مشكّلة صحيحة.
library;

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
    required this.yearNumber,
    required this.months,
    required this.classes,
    required this.workWeekdays,
    required this.holidayKeys,
    required this.font,
    required this.fontBold,
  });

  final AppDb db;
  final ReportsService reports;
  final String schoolName;
  final String directorName;
  final AcademicYear year;
  final int yearNumber;
  final List<int> months;
  final List<ExportScopeClass> classes;
  final Set<int> workWeekdays;
  final Set<String> holidayKeys;
  final pw.Font font;
  final pw.Font fontBold;

  pw.TextStyle _s(double size, {bool bold = false, PdfColor? color}) =>
      pw.TextStyle(
        font: bold ? fontBold : font,
        fontSize: size,
        color: color,
      );

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

  Future<pw.Document> build() async {
    final pw.Document doc = pw.Document(
      title: 'تقارير الحضور',
      theme: pw.ThemeData.withFont(base: font, bold: fontBold),
    );
    for (final int month in months) {
      for (final ExportScopeClass sc in classes) {
        final List<pw.Widget> rows = <pw.Widget>[
          _headerRow(),
        ];
        for (final Student s in sc.students) {
          final Map<String, int> byDate = <String, int>{
            for (final AttendanceRow r in await (db.select(db.attendanceRows)
                  ..where((a) =>
                      a.studentId.equals(s.id) & a.yearId.equals(year.id)))
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
            final DateTime d = DateTime(yearNumber, month, day);
            if (d.month != month) {
              cells.add(pw.SizedBox(width: 5, height: 9));
              continue;
            }
            final String key = SchoolTime.dateKey(d);
            final int? status = byDate[key];
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
                width: 5.5,
                height: 9,
                color: _colorFor(status, schoolDay),
                child: pw.Center(
                  child: pw.Text(
                    status == null ? '' : '${status + 1}',
                    style: _s(4.5),
                  ),
                ),
              ),
            );
          }
          final int recorded = present + absent + leave + late;
          cells.add(pw.Text('$absent', style: _s(6)));
          cells.add(pw.Text('$leave', style: _s(6)));
          cells.add(
            pw.Text(
              '${(recorded == 0 ? 100 : (present + late) * 100 / recorded).toStringAsFixed(1)}%',
              style: _s(6),
            ),
          );
          rows.add(
            pw.TableRow(
              children: <pw.Widget>[
                pw.Padding(padding: const PdfEdgeInsets.all(1), child: cells.first),
                pw.Container(child: pw.Row(children: cells.skip(1).toList())),
              ],
            ),
          );
        }
        doc.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4.landscape,
            header: (pw.Context c) => pw.Column(
              children: <pw.Widget>[
                pw.Text(
                  _t('$schoolName — ${sc.cls.grade} ـ ${sc.cls.section} — '
                      '${SchoolTime.monthNames[month - 1]} $yearNumber'),
                  style: _s(12, bold: true),
                ),
                pw.Text(
                  _t('المدير: $directorName — أخضر حاضر، أحمر غائب، أصفر إجازة، برتقالي متأخر'),
                  style: _s(7),
                ),
                pw.SizedBox(height: 4),
              ],
            ),
            build: (pw.Context c) => <pw.Widget>[
              pw.Table(
                columnWidths: const <int, TableColumnWidth>{
                  0: FlexColumnWidth(4),
                  1: FlexColumnWidth(14),
                },
                rows: rows,
              ),
            ],
          ),
        );
      }
    }
    return doc;
  }

  pw.TableRow _headerRow() => pw.TableRow(
        children: <pw.Widget>[
          pw.Text(_t('اسم الطالب'), style: _s(7, bold: true)),
          pw.Text(_t('أيام الشهر 1 → 31 ثم غياب/إجازة/نسبة'), style: _s(7, bold: true)),
        ],
      );

  Future<void> layout() async {
    final pw.Document doc = await build();
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: 'attendance-report.pdf',
    );
  }
}
