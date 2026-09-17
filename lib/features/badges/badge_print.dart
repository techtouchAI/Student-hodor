/// طباعة البادجات بمطابقة التصميم المعروض على الشاشة (`BadgeWidget`):
/// ترويسة متدرجة مع الختم الدائري (حلقة ذهبية + درع ونجمة)، شريط ذهبي،
/// صورة مؤطرة، اسم الطالب وصفه وعامه، ثم QR + Code128 + رقم الطالب —
/// كلها بالنسب نفسها من عرض الباج.
/// النص العربي يمر عبر خط التشكيل الداخلي (arabicForPdf) لأن حزم PDF
/// لا تشكّل العربية ذاتياً، ويُرسَم باتجاه LTR دائماً (ممنوع لفّه بأي
/// `Directionality` عربية).
///
/// ورقة A4 العرضية: شبكة 5×2 (10 بادجات) تبدأ من أعلى-يمين الورقة
/// (بداية السطر العربي) بفراغات محسوبة بدقة، والصف الناقص يلتصق باليمين.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:barcode/barcode.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/arabic_shaping.dart';
import 'badge_spec.dart';

/// خطّا البناء (عادي/عريض) — يُمرَّران صراحةً مع كل مستند بدل سجلّ عام
/// قابل للنسيان كان يُسقط بصمت على Helvetica فيخرّب العربية المطبوعة.
class _BadgeFonts {
  const _BadgeFonts(this.regular, this.bold);
  final pw.Font regular;
  final pw.Font bold;
}

class BadgePrint {
  const BadgePrint._();

  /// ألوان الباج مطابقة لـ`BadgePalette` في العرض.
  static const PdfColor _header = PdfColor.fromInt(0xFF0D6E5F);
  static const PdfColor _headerDark = PdfColor.fromInt(0xFF084C41);
  static const PdfColor _gold = PdfColor.fromInt(0xFFC9A227);
  static const PdfColor _background = PdfColor.fromInt(0xFFFAFAF8);
  static const PdfColor _ink = PdfColor.fromInt(0xFF1B1B1B);
  static const PdfColor _photoBg = PdfColor.fromInt(0xFFE3EDEA);

  /// شبكة ورقة A4 العرضية: 5 أعمدة × صفّان (CR80 عمودي).
  static const int _columns = 5;
  static const int _rowsPerPage = 2;
  static const int _perPage = _columns * _rowsPerPage;

  /// هامش الورقة من كل جهة + فراغ بين الصفين.
  static const double _marginMm = 8;
  static const double _rowGap = 10;

  /// عدد صفحات الورق اللازمة لعدد من الباجات.
  static int pagesFor(int count) =>
      count <= 0 ? 0 : ((count - 1) ~/ _perPage) + 1;

  static pw.TextStyle _style(
    _BadgeFonts fonts,
    double size, {
    bool bold = false,
    PdfColor? color,
  }) =>
      pw.TextStyle(
        font: bold ? fonts.bold : fonts.regular,
        fontSize: size,
        color: color,
      );

  static String _t(String s) => arabicForPdf(s);

  /// ورقة A4 عرضية: شبكة دقيقة من أعلى-يمين الورقة (لا توسّط).
  static pw.Document sheet(
    List<BadgeSpec> specs, {
    required pw.Font font,
    required pw.Font fontBold,
  }) {
    final _BadgeFonts fonts = _BadgeFonts(font, fontBold);
    final PdfPageFormat format = PdfPageFormat.a4.landscape;
    final double bw = BadgeMetrics.widthPt;
    final double bh = BadgeMetrics.heightPt;
    const double margin = _marginMm * PdfPageFormat.mm;
    final double contentW = format.width - margin * 2;
    // الفراغ الأفقي مشتق من العرض لا ثابت: 5 بادجات + 4 فراغات = العرض كاملاً.
    final double gapX = (contentW - _columns * bw) / (_columns - 1);
    final List<List<BadgeSpec>> pages = <List<BadgeSpec>>[];
    for (int i = 0; i < specs.length; i += _perPage) {
      pages.add(specs.sublist(i, (i + _perPage).clamp(0, specs.length)));
    }
    final pw.Document doc = pw.Document(
      title: 'بادجات الطلاب',
      theme: pw.ThemeData.withFont(base: font, bold: fontBold),
    );
    for (final List<BadgeSpec> page in pages) {
      final int rowsNeeded = ((page.length - 1) ~/ _columns) + 1;
      doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(margin),
          build: (pw.Context context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: <pw.Widget>[
              // العمود يبدأ من الأعلى افتراضياً: لا Spacer ولا توسّط قبله.
              for (int row = 0; row < rowsNeeded; row++) ...<pw.Widget>[
                if (row > 0) pw.SizedBox(height: _rowGap),
                _sheetRow(page, row, bw, bh, gapX, fonts),
              ],
            ],
          ),
        ),
      );
    }
    return doc;
  }

  /// صف واحد من الشبكة: الأول يميناً (بداية السطر العربي) ويمتلئ نحو
  /// اليسار. الصف الناقص (آخر صفحة) يلتصق باليمين بدل التوسّط.
  static pw.Widget _sheetRow(
    List<BadgeSpec> page,
    int row,
    double bw,
    double bh,
    double gapX,
    _BadgeFonts fonts,
  ) {
    final List<BadgeSpec> cells =
        page.skip(row * _columns).take(_columns).toList();
    // سياق PDF افتراضياً LTR، فنعكس الترتيب ليظهر الباج الأول يميناً.
    final List<pw.Widget> children = <pw.Widget>[];
    for (int i = cells.length - 1; i >= 0; i--) {
      if (children.isNotEmpty) {
        children.add(pw.SizedBox(width: gapX));
      }
      children.add(_badge(cells[i], bw, bh, fonts));
    }
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.end,
      children: children,
    );
  }

  /// بطاقة CR80 مفردة (لطابعات البطاقات): بلا هوامش، الباج يملأ الصفحة.
  static pw.Document single(
    BadgeSpec spec, {
    required pw.Font font,
    required pw.Font fontBold,
  }) {
    final _BadgeFonts fonts = _BadgeFonts(font, fontBold);
    final pw.Document doc = pw.Document(
      title: 'باج ${spec.studentName}',
      theme: pw.ThemeData.withFont(base: font, bold: fontBold),
    );
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(BadgeMetrics.widthPt, BadgeMetrics.heightPt),
        margin: pw.EdgeInsets.zero,
        build: (pw.Context context) =>
            _badge(spec, BadgeMetrics.widthPt, BadgeMetrics.heightPt, fonts),
      ),
    );
    return doc;
  }

  /// بطاقة واحدة بنسب `BadgeWidget` نفسها (كل القياسات من عرض الباج `w`).
  static pw.Widget _badge(BadgeSpec s, double w, double h, _BadgeFonts fonts) {
    final double radius = w * 0.05;
    return pw.Container(
      width: w,
      height: h,
      decoration: pw.BoxDecoration(
        color: _background,
        borderRadius: pw.BorderRadius.circular(radius),
        border: pw.Border.all(color: _headerDark, width: 1.2),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: <pw.Widget>[
          _badgeHeader(s, w, radius, fonts),
          pw.Container(height: w * 0.02, color: _gold),
          pw.Expanded(
            child: pw.Padding(
              padding: pw.EdgeInsets.all(w * 0.05),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: <pw.Widget>[
                  _photo(s, w, fonts),
                  pw.SizedBox(height: w * 0.03),
                  pw.Text(
                    _t(s.studentName),
                    textAlign: pw.TextAlign.center,
                    maxLines: 2,
                    style: _style(fonts, w * 0.075, bold: true, color: _ink),
                  ),
                  pw.SizedBox(height: w * 0.015),
                  pw.Text(
                    _t(s.classLine),
                    maxLines: 1,
                    style: _style(fonts, w * 0.052, color: _ink),
                  ),
                  pw.Text(
                    _t(s.yearLine),
                    maxLines: 1,
                    style: _style(fonts, w * 0.052, color: _ink),
                  ),
                  pw.Spacer(),
                  _codes(s, w, fonts),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// الترويسة: متدرجة داكن→فاتح من الأعلى، بزاويتين علويتين مدورتين
  /// تعشّقان داخل إطار البطاقة. الترتيب معكوس عن الشاشة لأن سياق PDF
  /// LTR: النص يميناً والختم يساراً كما في العرض العربي.
  static pw.Widget _badgeHeader(
    BadgeSpec s,
    double w,
    double radius,
    _BadgeFonts fonts,
  ) =>
      pw.Container(
        padding: pw.EdgeInsets.symmetric(
          vertical: w * 0.045,
          horizontal: w * 0.04,
        ),
        decoration: pw.BoxDecoration(
          gradient: const pw.LinearGradient(
            colors: <PdfColor>[_headerDark, _header],
            begin: pw.Alignment.topCenter,
            end: pw.Alignment.bottomCenter,
          ),
          borderRadius: pw.BorderRadius.only(
            topLeft: pw.Radius.circular(radius - 1.2),
            topRight: pw.Radius.circular(radius - 1.2),
          ),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: <pw.Widget>[
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: <pw.Widget>[
                  pw.Text(
                    _t(s.schoolName),
                    textAlign: pw.TextAlign.right,
                    maxLines: 2,
                    style: _style(fonts,
                      w * 0.062,
                      bold: true,
                      color: PdfColors.white,
                    ),
                  ),
                  pw.SizedBox(height: w * 0.008),
                  pw.Text(
                    _t('المدير: ${s.directorName}'),
                    textAlign: pw.TextAlign.right,
                    maxLines: 1,
                    style: _style(fonts, w * 0.04, color: PdfColors.teal50),
                  ),
                ],
              ),
            ),
            pw.SizedBox(width: w * 0.03),
            _emblem(w * 0.16),
          ],
        ),
      );

  /// الختم الدائري كما في العرض: حلقة ذهبية، قرص أبيض، قرص أخضر،
  /// درع أبيض بنجمة — يُرسَم بأشكال متجهة (دوائر + مضلّعات).
  static pw.Widget _emblem(double e) {
    final double c = e / 2;
    final double r = e / 2;
    final List<PdfPoint> shield = <PdfPoint>[
      PdfPoint(c, c - 0.42 * r),
      PdfPoint(c + 0.34 * r, c - 0.18 * r),
      PdfPoint(c + 0.30 * r, c + 0.26 * r),
      PdfPoint(c, c + 0.46 * r),
      PdfPoint(c - 0.30 * r, c + 0.26 * r),
      PdfPoint(c - 0.34 * r, c - 0.18 * r),
    ];
    final List<PdfPoint> star = <PdfPoint>[];
    final double sr = r * 0.18;
    for (int i = 0; i < 10; i++) {
      final double rad = i.isEven ? sr : sr * 0.45;
      final double a = -math.pi / 2 + i * math.pi / 5;
      star.add(PdfPoint(c + rad * math.cos(a), c + rad * math.sin(a)));
    }
    return pw.SizedBox(
      width: e,
      height: e,
      child: pw.Stack(
        alignment: pw.Alignment.center,
        children: <pw.Widget>[
          pw.Circle(fillColor: _gold),
          pw.Padding(
            padding: pw.EdgeInsets.all(e * 0.06),
            child: pw.Circle(fillColor: PdfColors.white),
          ),
          pw.Padding(
            padding: pw.EdgeInsets.all(e * 0.13),
            child: pw.Circle(fillColor: _header),
          ),
          pw.Polygon(points: shield, fillColor: PdfColors.white),
          pw.Polygon(points: star, fillColor: _header),
        ],
      ),
    );
  }

  /// الصورة مؤطرة بحواف مدورة كما في العرض، وإن غابت فمربع ملوّن
  /// يحمل الحرف الأول من اسم الطالب (بديل الطباعة لأيقونة الشاشة).
  static pw.Widget _photo(BadgeSpec s, double w, _BadgeFonts fonts) {
    final double photoW = w * 0.34;
    final double photoH = w * 0.42;
    final List<int>? bytes = s.photoBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return pw.Container(
        width: photoW,
        height: photoH,
        decoration: pw.BoxDecoration(
          borderRadius: pw.BorderRadius.circular(w * 0.05),
          border: pw.Border.all(color: _header, width: 1.4),
          image: pw.DecorationImage(
            image: pw.MemoryImage(Uint8List.fromList(bytes)),
            fit: pw.BoxFit.cover,
          ),
        ),
      );
    }
    final String name = s.studentName.trim();
    final String initial = name.isEmpty ? '؟' : name[0];
    return pw.Container(
      width: photoW,
      height: photoH,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        color: _photoBg,
        borderRadius: pw.BorderRadius.circular(w * 0.05),
        border: pw.Border.all(color: _header, width: 1.4),
      ),
      child: pw.Text(
        _t(initial),
        style: _style(fonts, w * 0.16, bold: true, color: _header),
      ),
    );
  }

  /// شريط الرموز: QR يميناً وCode128 مع رقم الطالب يساراً كما في العرض.
  static pw.Widget _codes(BadgeSpec s, double w, _BadgeFonts fonts) => pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: <pw.Widget>[
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            mainAxisSize: pw.MainAxisSize.min,
            children: <pw.Widget>[
              pw.BarcodeWidget(
                barcode: Barcode.code128(),
                data: s.code,
                width: w * 0.52,
                height: w * 0.10,
              ),
              pw.SizedBox(height: w * 0.012),
              pw.Text(
                _t(s.seqLine),
                maxLines: 1,
                style: _style(fonts, w * 0.045, color: _ink),
              ),
            ],
          ),
          pw.SizedBox(width: w * 0.03),
          pw.BarcodeWidget(
            barcode: Barcode.qrCode(),
            data: s.code,
            width: w * 0.28,
            height: w * 0.28,
          ),
        ],
      );

  /// معاينة/طباعة عبر إطار طباعة أندرويد (مشاركة، حفظ PDF، طابعة).
  ///
  /// صيغة مهمة الطباعة [format] يجب أن تطابق صفحات المستند: الافتراضي
  /// بورتريه، ولو خالفت الصفحات (عرضية/مخصصة) لاحتواها النظام بتحجيم
  /// وتوسيط فيبدأ المحتوى بعيداً عن أول الورقة بشرائط فارغة.
  static Future<void> layout(pw.Document doc, PdfPageFormat format) =>
      Printing.layoutPdf(
        onLayout: (PdfPageFormat f) async => doc.save(),
        name: 'بادجات الطلاب.pdf',
        format: format,
      );
}
