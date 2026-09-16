/// تقرير PDF شهري ملوّن واحترافي مطابق لمنطق الإكسل، بعربية مشكّلة صحيحة.
/// باتجاه RTL سليم: تسلسل واسم الطالب في اليمين، أيام الشهر، والمجاميع في اليسار.
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

  static const double _dayW = 17.5;

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

  String _cellLetter(int? status, bool schoolDay) {
    if (!schoolDay) {
      return _t('ع');
    }
    switch (status) {
      case AttendanceStatus.present:
        return _t('ح');
      case AttendanceStatus.absent:
        return _t('غ');
      case AttendanceStatus.leave:
        return _t('ج');
      case AttendanceStatus.late:
        return _t('م');
      default:
        return '';
    }
  }

  PdfColor _letterColor(int? status, bool schoolDay) {
    if (!schoolDay) {
      return const PdfColor.fromInt(0xFF757575);
    }
    switch (status) {
      case AttendanceStatus.present:
        return const PdfColor.fromInt(0xFF1E7E34);
      case AttendanceStatus.absent:
        return const PdfColor.fromInt(0xFFB71C1C);
      case AttendanceStatus.leave:
        return const PdfColor.fromInt(0xFF8A6D3B);
      case AttendanceStatus.late:
        return const PdfColor.fromInt(0xFFD35400);
      default:
        return PdfColors.black;
    }
  }

  Map<int, pw.TableColumnWidth> _dailyWidths() => <int, pw.TableColumnWidth>{
        0: const pw.FixedColumnWidth(28),
        1: const pw.FixedColumnWidth(22),
        2: const pw.FixedColumnWidth(22),
        3: const pw.FixedColumnWidth(22),
        4: const pw.FixedColumnWidth(22),
        for (int i = 5; i <= 35; i++) i: const pw.FixedColumnWidth(_dayW),
        36: const pw.FlexColumnWidth(1),
        37: const pw.FixedColumnWidth(18),
      };

  pw.TableRow _headerRow(MonthKey m) {
    final List<pw.Widget> cells = <pw.Widget>[
      _th(_t('النسبة')),
      _th(_t('إجازة')),
      _th(_t('غياب')),
      _th(_t('متأخر')),
      _th(_t('حاضر')),
    ];
    for (int day = 31; day >= 1; day--) {
      cells.add(
        pw.Container(
          height: 15,
          color: m.isValidDay(day)
              ? PdfColors.teal800
              : const PdfColor.fromInt(0xFF004D40),
          alignment: pw.Alignment.center,
          child: pw.Text(
            m.isValidDay(day) ? '$day' : '',
            style: _s(6, bold: true, color: PdfColors.white),
          ),
        ),
      );
    }
    cells.add(_th(_t('اسم الطالب'), align: pw.Alignment.centerRight, padH: 4));
    cells.add(_th(_t('ت')));
    return pw.TableRow(children: cells);
  }

  pw.Widget _th(
    String text, {
    pw.Alignment align = pw.Alignment.center,
    double padH = 1,
  }) =>
      pw.Container(
        height: 15,
        color: PdfColors.teal800,
        alignment: align,
        padding: pw.EdgeInsets.symmetric(horizontal: padH),
        child: pw.Text(
          text,
          style: _s(6.5, bold: true, color: PdfColors.white),
          textAlign: pw.TextAlign.center,
        ),
      );

  pw.Widget _legendItem(String label, PdfColor color) => pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: <pw.Widget>[
          pw.Text(_t(label), style: _s(6.5, bold: true)),
          pw.SizedBox(width: 3),
          pw.Container(
            width: 8,
            height: 8,
            decoration: pw.BoxDecoration(
              color: color,
              border: pw.Border.all(color: PdfColors.grey600, width: 0.5),
            ),
          ),
        ],
      );

  Future<pw.Document> build() async {
    final pw.Document doc = pw.Document(
      title: 'تقارير الحضور والغياب',
      theme: pw.ThemeData.withFont(base: font, bold: fontBold),
    );
    if (includeDaily) {
      for (final MonthKey m in months) {
        for (final ExportScopeClass sc in classes) {
          final List<pw.TableRow> rows = <pw.TableRow>[_headerRow(m)];
          for (int studentIdx = 0; studentIdx < sc.students.length; studentIdx++) {
            final Student s = sc.students[studentIdx];
            final Map<String, int> byDate = <String, int>{
              for (final AttendanceRow r in await (db.select(db.attendanceRows)
                    ..where(
                      (a) =>
                          a.studentId.equals(s.id) & a.yearId.equals(year.id),
                    ))
                  .get())
                r.date: r.status,
            };
            int absent = 0;
            int leave = 0;
            int present = 0;
            int late = 0;

            final Map<int, (int?, bool)> dayStatuses = <int, (int?, bool)>{};
            for (int day = 1; day <= 31; day++) {
              if (!m.isValidDay(day)) {
                continue;
              }
              final DateTime d = DateTime(m.year, m.month, day);
              final int? status = byDate[SchoolTime.dateKey(d)];
              final bool schoolDay = SchoolTime.isSchoolDay(
                d,
                workWeekdays: workWeekdays,
                holidayKeys: holidayKeys,
              );
              dayStatuses[day] = (status, schoolDay);
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
            }

            final int recorded = present + absent + leave + late;
            final String rateStr = recorded == 0
                ? '100%'
                : '${((present + late) * 100 / recorded).toStringAsFixed(0)}%';

            final List<pw.Widget> cells = <pw.Widget>[
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text(rateStr, style: _s(6, bold: true)),
              ),
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text('$leave', style: _s(6)),
              ),
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text(
                  '$absent',
                  style: _s(
                    6,
                    bold: absent > 0,
                    color: absent > 0 ? PdfColors.red900 : PdfColors.black,
                  ),
                ),
              ),
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text('$late', style: _s(6)),
              ),
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text('$present', style: _s(6)),
              ),
            ];

            for (int day = 31; day >= 1; day--) {
              if (!m.isValidDay(day)) {
                cells.add(
                  pw.Container(
                    height: 13,
                    color: const PdfColor.fromInt(0xFFE8E8E8),
                  ),
                );
                continue;
              }
              final (int?, bool) info =
                  dayStatuses[day] ?? (null, true);
              final int? status = info.$1;
              final bool schoolDay = info.$2;
              cells.add(
                pw.Container(
                  height: 13,
                  color: _colorFor(status, schoolDay),
                  alignment: pw.Alignment.center,
                  child: pw.Text(
                    _cellLetter(status, schoolDay),
                    style: _s(
                      5,
                      bold: true,
                      color: _letterColor(status, schoolDay),
                    ),
                  ),
                ),
              );
            }

            cells.add(
              pw.Container(
                height: 13,
                alignment: pw.Alignment.centerRight,
                padding: const pw.EdgeInsets.symmetric(horizontal: 4),
                child: pw.Text(
                  _t(s.fullName),
                  style: _s(6.5, bold: true),
                  maxLines: 1,
                ),
              ),
            );
            cells.add(
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text('${studentIdx + 1}', style: _s(6)),
              ),
            );

            rows.add(pw.TableRow(children: cells));
          }

          doc.addPage(
            pw.MultiPage(
              pageFormat: PdfPageFormat.a4.landscape,
              margin: const pw.EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              header: (pw.Context c) => pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: <pw.Widget>[
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: <pw.Widget>[
                      pw.Text(
                        _t('نظام حضور الطالب — كشف الحضور والغياب الشهري'),
                        style: _s(7.5, color: PdfColors.grey700),
                      ),
                      pw.Text(
                        _t('$schoolName — ${sc.cls.grade} ـ ${sc.cls.section} — ${m.label}'),
                        style: _s(11, bold: true, color: PdfColors.teal900),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 3),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: <pw.Widget>[
                      pw.Row(
                        children: <pw.Widget>[
                          _legendItem('عطلة', const PdfColor.fromInt(0xFFD9D9D9)),
                          pw.SizedBox(width: 8),
                          _legendItem('متأخر', const PdfColor.fromInt(0xFFFCD5B4)),
                          pw.SizedBox(width: 8),
                          _legendItem('إجازة', const PdfColor.fromInt(0xFFFFEB9C)),
                          pw.SizedBox(width: 8),
                          _legendItem('غائب', const PdfColor.fromInt(0xFFFFC7CE)),
                          pw.SizedBox(width: 8),
                          _legendItem('حاضر', const PdfColor.fromInt(0xFFC6EFCE)),
                        ],
                      ),
                      pw.Text(
                        _t('المدير: $directorName — السنة: ${year.name}'),
                        style: _s(7.5, bold: true),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 4),
                ],
              ),
              build: (pw.Context c) => <pw.Widget>[
                if (sc.students.isEmpty)
                  pw.Center(
                    child: pw.Padding(
                      padding: const pw.EdgeInsets.all(32),
                      child: pw.Text(
                        _t('لا طلاب مسجلون في هذا الصف بعد'),
                        style: _s(10),
                      ),
                    ),
                  )
                else
                  pw.Table(
                    columnWidths: _dailyWidths(),
                    border: pw.TableBorder.all(
                      width: 0.5,
                      color: PdfColors.grey400,
                    ),
                    defaultVerticalAlignment:
                        pw.TableCellVerticalAlignment.middle,
                    children: rows,
                  ),
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
            _th(_t('نسبة الحضور')),
            _th(_t('إجازة')),
            _th(_t('غياب')),
            _th(_t('متأخر')),
            _th(_t('حاضر')),
            _th(_t('اسم الطالب'), align: pw.Alignment.centerRight, padH: 6),
            _th(_t('ت')),
          ],
        ),
      ];
      for (int studentIdx = 0; studentIdx < sc.students.length; studentIdx++) {
        final Student s = sc.students[studentIdx];
        final StatusTotals t = await reports.totalsForStudent(s.id, year.id);
        rows.add(
          pw.TableRow(
            children: <pw.Widget>[
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text(
                  '${t.ratePct.toStringAsFixed(1)}%',
                  style: _s(6.5, bold: true),
                ),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text('${t.leave}', style: _s(6.5)),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text(
                  '${t.absent}',
                  style: _s(
                    6.5,
                    bold: t.absent > 0,
                    color: t.absent > 0 ? PdfColors.red900 : PdfColors.black,
                  ),
                ),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text('${t.late}', style: _s(6.5)),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text('${t.present}', style: _s(6.5)),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.centerRight,
                padding: const pw.EdgeInsets.symmetric(horizontal: 6),
                child: pw.Text(
                  _t(s.fullName),
                  style: _s(6.5, bold: true),
                  maxLines: 1,
                ),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text('${studentIdx + 1}', style: _s(6.5)),
              ),
            ],
          ),
        );
      }
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
          header: (pw.Context c) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: <pw.Widget>[
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  pw.Text(
                    _t('نظام حضور الطالب — ملخص السنة الدراسية'),
                    style: _s(8, color: PdfColors.grey700),
                  ),
                  pw.Text(
                    _t('$schoolName — ملخص السنة — ${sc.cls.grade} ـ ${sc.cls.section}'),
                    style: _s(11, bold: true, color: PdfColors.teal900),
                  ),
                ],
              ),
              pw.SizedBox(height: 3),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  pw.Text(
                    _t('السنة الدراسية: ${year.name} (${year.start} → ${year.end})'),
                    style: _s(8),
                  ),
                  pw.Text(_t('المدير: $directorName'), style: _s(8, bold: true)),
                ],
              ),
              pw.SizedBox(height: 6),
            ],
          ),
          build: (pw.Context c) => <pw.Widget>[
            if (sc.students.isEmpty)
              pw.Center(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.all(32),
                  child: pw.Text(
                    _t('لا طلاب مسجلون في هذا الصف بعد'),
                    style: _s(10),
                  ),
                ),
              )
            else
              pw.Table(
                columnWidths: <int, pw.TableColumnWidth>{
                  0: const pw.FixedColumnWidth(70),
                  1: const pw.FixedColumnWidth(55),
                  2: const pw.FixedColumnWidth(55),
                  3: const pw.FixedColumnWidth(55),
                  4: const pw.FixedColumnWidth(55),
                  5: const pw.FlexColumnWidth(1),
                  6: const pw.FixedColumnWidth(25),
                },
                border: pw.TableBorder.all(
                  width: 0.5,
                  color: PdfColors.grey400,
                ),
                defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
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
