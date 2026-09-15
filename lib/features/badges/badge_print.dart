/// طباعة البادجات: ورقة A4 عرضية (10 بادجات) أو بطاقة CR80 مفردة.
/// النص العربي يمر عبر خط التشكيل الداخلي (arabicForPdf) لأن حزم PDF
/// لا تشكّل العربية ذاتياً.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:barcode/barcode.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/arabic_shaping.dart';
import 'badge_spec.dart';

class BadgePrint {
  const BadgePrint._();

  static pw.Font? _font;
  static pw.Font? _fontBold;

  static void registerFonts(pw.Font regular, pw.Font bold) {
    _font = regular;
    _fontBold = bold;
  }

  static pw.TextStyle _style(double size, {bool bold = false}) => pw.TextStyle(
        font: bold ? _fontBold : _font,
        fontSize: size,
      );

  static String _t(String s) => arabicForPdf(s);

  /// ورقة A4 عرضية: شبكة 5×2 بادجات مع هوامش قص.
  static pw.Document sheet(List<BadgeSpec> specs) {
    final pw.Font? font = _font;
    final pw.Font? bold = _fontBold;
    final PdfPageFormat format = PdfPageFormat.a4.landscape;
    final double bw = BadgeMetrics.widthPt;
    final double bh = BadgeMetrics.heightPt;
    final List<List<BadgeSpec>> pages = <List<BadgeSpec>>[];
    for (int i = 0; i < specs.length; i += 10) {
      pages.add(specs.sublist(i, (i + 10).clamp(0, specs.length)));
    }
    final pw.Document doc = pw.Document(
      title: 'بادجات الطلاب',
      theme: pw.ThemeData.withFont(base: font, bold: bold),
    );
    for (final List<BadgeSpec> page in pages) {
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(12),
          build: (pw.Context context) => pw.Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: pw.WrapAlignment.center,
            runAlignment: pw.WrapAlignment.center,
            children: <pw.Widget>[
              for (final BadgeSpec s in page) _badge(s, bw, bh),
            ],
          ),
        ),
      );
    }
    return doc;
  }

  /// بطاقة CR80 مفردة (لطابعات البطاقات).
  static pw.Document single(BadgeSpec spec) {
    final pw.Document doc = pw.Document(
      title: 'باج ${spec.studentName}',
      theme: pw.ThemeData.withFont(base: _font, bold: _fontBold),
    );
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(BadgeMetrics.widthPt, BadgeMetrics.heightPt),
        build: (pw.Context context) =>
            _badge(spec, BadgeMetrics.widthPt, BadgeMetrics.heightPt),
      ),
    );
    return doc;
  }

  static pw.Widget _badge(BadgeSpec s, double w, double h) => pw.Container(
        width: w,
        height: h,
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.teal900, width: 0.8),
          color: PdfColors.grey50,
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: <pw.Widget>[
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 3),
              decoration: const pw.BoxDecoration(color: PdfColors.teal800),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: <pw.Widget>[
                  pw.Container(
                    width: 16,
                    height: 16,
                    decoration: pw.BoxDecoration(
                      color: PdfColors.white,
                      shape: pw.BoxShape.circle,
                      border: pw.Border.all(color: PdfColors.amber800, width: 1.2),
                    ),
                    child: pw.Center(
                      child: pw.Text(
                        _t(s.schoolName.isEmpty ? 'م' : s.schoolName.trim()[0]),
                        style: _style(8, bold: true).copyWith(color: PdfColors.teal800),
                      ),
                    ),
                  ),
                  pw.SizedBox(width: 3),
                  pw.Expanded(
                    child: pw.Column(
                      children: <pw.Widget>[
                        pw.Text(
                          _t(s.schoolName),
                          textAlign: pw.TextAlign.center,
                          style: _style(7.5, bold: true).copyWith(color: PdfColors.white),
                        ),
                        pw.Text(
                          _t('المدير: ${s.directorName}'),
                          textAlign: pw.TextAlign.center,
                          style: _style(5).copyWith(color: PdfColors.teal50),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            pw.Container(height: 1.6, color: PdfColors.amber800),
            pw.Expanded(
              child: pw.Padding(
                padding: const pw.EdgeInsets.all(4),
                child: pw.Column(
                  children: <pw.Widget>[
                    if (s.photoBytes != null && s.photoBytes!.isNotEmpty)
                      pw.Container(
                        width: w * 0.32,
                        height: w * 0.40,
                        decoration: pw.BoxDecoration(
                          border: pw.Border.all(color: PdfColors.teal800),
                        ),
                        child: pw.Image(
                          pw.MemoryImage(Uint8List.fromList(s.photoBytes!)),
                          fit: pw.BoxFit.cover,
                        ),
                      )
                    else
                      pw.Container(
                        width: w * 0.32,
                        height: w * 0.40,
                        decoration: pw.BoxDecoration(
                          border: pw.Border.all(color: PdfColors.teal800),
                          color: PdfColors.teal50,
                        ),
                        child: pw.Center(child: pw.SizedBox()),
                      ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      _t(s.studentName),
                      textAlign: pw.TextAlign.center,
                      maxLines: 2,
                      style: _style(8.5, bold: true),
                    ),
                    pw.SizedBox(height: 1),
                    pw.Text(_t(s.classLine), style: _style(6.5)),
                    pw.Text(_t(s.yearLine), style: _style(6)),
                    pw.Spacer(),
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: <pw.Widget>[
                        pw.BarcodeWidget(
                          barcode: Barcode.qrCode(),
                          data: s.code,
                          width: w * 0.28,
                          height: w * 0.28,
                        ),
                        pw.Spacer(),
                        pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.end,
                          children: <pw.Widget>[
                            pw.BarcodeWidget(
                              barcode: Barcode.code128(),
                              data: s.code,
                              width: w * 0.52,
                              height: 11,
                            ),
                            pw.SizedBox(height: 1),
                            pw.Text(_t(s.seqLine), style: _style(5.5)),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  /// معاينة/طباعة عبر إطار طباعة أندرويد (مشاركة، حفظ PDF، طابعة).
  static Future<void> layout(pw.Document doc) => Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => doc.save(),
        name: 'badges.pdf',
      );
}
