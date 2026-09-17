/// سجل الطالب الكامل PDF (بورتريه): يوم لكل صف من بداية السنة حتى اليوم
/// + كتلة الإحصائيات الكلية — يُصدَّر من ملف الطالب.
/// يستهلك [StudentRecord] نفسه الذي يستهلكه تصدير Excel فلا يتباعدان.
library;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/arabic_shaping.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/reports_service.dart';

class StudentRecordPdf {
  StudentRecordPdf({
    required this.reports,
    required this.schoolName,
    required this.directorName,
    required this.year,
    required this.student,
    required this.classTitle,
    required this.workWeekdays,
    required this.holidayKeys,
    required this.font,
    required this.fontBold,
    this.today,
  });

  final ReportsService reports;
  final String schoolName;
  final String directorName;
  final AcademicYear year;
  final Student student;
  final String classTitle;
  final Set<int> workWeekdays;
  final Set<String> holidayKeys;
  final pw.Font font;
  final pw.Font fontBold;
  final DateTime? today;

  static const List<String> _statusAr = <String>[
    'حاضر',
    'غائب',
    'إجازة',
    'متأخر',
  ];

  /// صفوف كل جدول: الجدول الواحد لا يُقسَّم تلقائياً بموثوقية داخل
  /// MultiPage، فنقطّع الأيام لمقاطع يسع المقطعُ الصفحةَ حتماً.
  static const int _chunkRows = 44;

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

  String _statusText(int? status, bool schoolDay) {
    if (status != null) {
      return _statusAr[status];
    }
    return schoolDay ? 'لم يسجل' : 'عطلة';
  }

  pw.Widget _th(String text) => pw.Container(
        height: 16,
        color: PdfColors.teal800,
        alignment: pw.Alignment.center,
        child: pw.Text(
          _t(text),
          style: _s(8, bold: true, color: PdfColors.white),
          textAlign: pw.TextAlign.center,
        ),
      );

  pw.Widget _td(String text, {PdfColor? color, bool bold = false}) =>
      pw.Container(
        height: 14,
        color: color,
        alignment: pw.Alignment.center,
        child: pw.Text(
          _t(text),
          style: _s(7.5, bold: bold),
          textAlign: pw.TextAlign.center,
          maxLines: 1,
        ),
      );

  Future<pw.Document> build() async {
    final StudentRecord record = await reports.studentRecord(
      studentId: student.id,
      year: year,
      workWeekdays: workWeekdays,
      holidayKeys: holidayKeys,
      today: today,
    );
    final StatusTotals t = record.totals;
    final pw.Document doc = pw.Document(
      title: 'سجل الطالب ${student.fullName}',
      theme: pw.ThemeData.withFont(base: font, bold: fontBold),
    );
    final List<pw.TableRow> head = <pw.TableRow>[
      pw.TableRow(
        children: <pw.Widget>[
          _th('م'),
          _th('التاريخ'),
          _th('اليوم'),
          _th('الحالة'),
        ],
      ),
    ];
    final Map<int, pw.TableColumnWidth> widths = <int, pw.TableColumnWidth>{
      0: const pw.FixedColumnWidth(30),
      1: const pw.FixedColumnWidth(90),
      2: const pw.FixedColumnWidth(110),
      3: const pw.FlexColumnWidth(1),
    };
    int index = 1;
    final List<List<pw.TableRow>> chunks = <List<pw.TableRow>>[];
    List<pw.TableRow> current = <pw.TableRow>[...head];
    for (final RecordDay d in record.days) {
      final DateTime dt = SchoolTime.parseKey(d.dateKey);
      current.add(
        pw.TableRow(
          children: <pw.Widget>[
            _td('$index'),
            _td(d.dateKey),
            _td(SchoolTime.weekdayNames[dt.weekday - 1]),
            _td(
              _statusText(d.status, d.schoolDay),
              color: _colorFor(d.status, d.schoolDay),
            ),
          ],
        ),
      );
      index++;
      if (current.length > _chunkRows) {
        chunks.add(current);
        current = <pw.TableRow>[...head];
      }
    }
    if (current.length > 1 || record.days.isEmpty) {
      chunks.add(current);
    }
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        header: (pw.Context c) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: <pw.Widget>[
            pw.Text(
              _t('$schoolName — سجل الطالب'),
              style: _s(12, bold: true, color: PdfColors.teal900),
              textAlign: pw.TextAlign.center,
            ),
            pw.Text(
              _t(
                '${student.fullName} — $classTitle — السنة ${year.name} — '
                'حتى ${record.to}',
              ),
              style: _s(9),
              textAlign: pw.TextAlign.center,
            ),
            if (directorName.trim().isNotEmpty)
              pw.Text(
                _t('المدير: $directorName'),
                style: _s(8, color: PdfColors.grey700),
                textAlign: pw.TextAlign.center,
              ),
            pw.SizedBox(height: 6),
          ],
        ),
        build: (pw.Context c) => <pw.Widget>[
          for (final List<pw.TableRow> rows in chunks) ...<pw.Widget>[
            pw.Table(
              columnWidths: widths,
              border: pw.TableBorder.all(width: 0.5, color: PdfColors.grey400),
              defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
              children: rows,
            ),
            pw.SizedBox(height: 8),
          ],
          pw.Table(
            columnWidths: const <int, pw.TableColumnWidth>{
              0: pw.FlexColumnWidth(1),
              1: pw.FixedColumnWidth(70),
            },
            border: pw.TableBorder.all(width: 0.5, color: PdfColors.grey400),
            defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
            children: <pw.TableRow>[
              pw.TableRow(
                children: <pw.Widget>[
                  _th('الإحصائية الكلية'),
                  _th('العدد'),
                ],
              ),
              for (final (String, String) st in <(String, String)>[
                ('إجمالي الحضور', '${t.present}'),
                ('إجمالي الغياب', '${t.absent}'),
                ('إجمالي الإجازات', '${t.leave}'),
                ('إجمالي التأخير', '${t.late}'),
                ('أيام مسجلة', '${t.recorded}'),
                ('نسبة الحضور %', t.ratePct.toStringAsFixed(1)),
              ])
                pw.TableRow(
                  children: <pw.Widget>[_td(st.$1), _td(st.$2, bold: true)],
                ),
            ],
          ),
        ],
      ),
    );
    return doc;
  }

  /// الصفحات بورتريه ومهمة الطباعة بورتريه: تطابق يمنع شرائط الاحتواء.
  Future<void> layout() async {
    final pw.Document doc = await build();
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: 'سجل الطالب.pdf',
      format: PdfPageFormat.a4,
    );
  }
}
