/// عرض الباج على الشاشة بمطابقة النموذج البصري (docs/badge-concept-front.png):
/// ترويسة متدرجة مع ختم دائري، شريط ذهبي، نقش guilloche خفيف، صورة مؤطرة،
/// اسم الطالب وصفه وعامه، ثم QR + Code128 + رقم الطالب.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import 'badge_spec.dart';

class BadgeWidget extends StatelessWidget {
  const BadgeWidget({super.key, required this.spec, this.width = 270});

  final BadgeSpec spec;
  final double width;

  double get _height => width * BadgeMetrics.heightMm / BadgeMetrics.widthMm;

  @override
  Widget build(BuildContext context) {
    final TextStyle nameStyle = TextStyle(
      fontSize: width * 0.075,
      fontWeight: FontWeight.bold,
      color: BadgePalette.ink,
    );
    final TextStyle lineStyle = TextStyle(
      fontSize: width * 0.052,
      color: BadgePalette.ink,
    );
    // الباج يُصمَّم مرة واحدة بمقاس ثابت ثم **يُصغَّر** ليلائم أي خلية شبكة أو
    // حوار معاينة. كان العمود سابقاً يعتمد `Expanded`/`Spacer` داخل ارتفاع
    // الخلية، فإذا ضاقت الخلية (شاشة صغيرة/خط كبير) حدث RenderFlex overflow
    // وسقط رسم البطاقة. التصميم الثابت + FittedBox يجعله مستحيلاً.
    return FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.center,
      child: SizedBox(
        width: width,
        height: _height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: BadgePalette.background,
            borderRadius: BorderRadius.circular(width * 0.05),
            border: Border.all(color: BadgePalette.headerDark, width: 1.2),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 6,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(width * 0.05),
            child: Column(
              children: <Widget>[
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    vertical: width * 0.045,
                    horizontal: width * 0.04,
                  ),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: <Color>[
                        BadgePalette.headerDark,
                        BadgePalette.header,
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      _Emblem(size: width * 0.16),
                      SizedBox(width: width * 0.03),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              spec.schoolName,
                              textAlign: TextAlign.start,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: width * 0.062,
                              ),
                            ),
                            SizedBox(height: width * 0.008),
                            Text(
                              'المدير: ${spec.directorName}',
                              textAlign: TextAlign.start,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: width * 0.040,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Container(height: width * 0.02, color: BadgePalette.gold),
                Expanded(
                  child: CustomPaint(
                    painter: _GuillochePainter(),
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.all(width * 0.05),
                      child: Column(
                        children: <Widget>[
                          _photo(width),
                          SizedBox(height: width * 0.03),
                          Text(
                            spec.studentName,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: nameStyle,
                          ),
                          SizedBox(height: width * 0.015),
                          Text(
                            spec.classLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: lineStyle,
                          ),
                          Text(
                            spec.yearLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: lineStyle,
                          ),
                          SizedBox(height: width * 0.04),
                          // شريط الرموز بمقاس طبيعي ثابت ثم يُصغَّر ككل إن ضاقت
                          // الخلية — يستحيل أن يفيض أو يقطع الرموز.
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.center,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                _QrView(data: spec.code, size: width * 0.28),
                                SizedBox(width: width * 0.03),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    _Code128View(
                                      data: spec.code,
                                      width: width * 0.52,
                                      height: width * 0.10,
                                    ),
                                    SizedBox(height: width * 0.012),
                                    Text(
                                      spec.seqLine,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: width * 0.045,
                                        color: BadgePalette.ink,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _photo(double w) {
    final List<int>? bytes = spec.photoBytes;
    if (bytes == null || bytes.isEmpty) {
      return Container(
        width: w * 0.34,
        height: w * 0.42,
        decoration: BoxDecoration(
          color: const Color(0xFFE3EDEA),
          borderRadius: BorderRadius.circular(w * 0.05),
          border: Border.all(color: BadgePalette.header, width: 1.4),
        ),
        child: Icon(Icons.person, size: w * 0.2, color: BadgePalette.header),
      );
    }
    return Container(
      width: w * 0.34,
      height: w * 0.42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(w * 0.05),
        border: Border.all(color: BadgePalette.header, width: 1.4),
        image: DecorationImage(
          image: MemoryImage(Uint8List.fromList(bytes)),
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

/// ختم دائري مبسّط: حلقة ذهبية، قرص أبيض، درع أخضر بنجمة.
class _Emblem extends StatelessWidget {
  const _Emblem({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _EmblemPainter(),
      );
}

class _EmblemPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.width / 2;
    canvas.drawCircle(
      c,
      r,
      Paint()..color = BadgePalette.gold,
    );
    canvas.drawCircle(c, r * 0.88, Paint()..color = Colors.white);
    canvas.drawCircle(c, r * 0.74, Paint()..color = BadgePalette.header);
    final Path shield = Path()
      ..moveTo(c.dx, c.dy - r * 0.42)
      ..lineTo(c.dx + r * 0.34, c.dy - r * 0.18)
      ..lineTo(c.dx + r * 0.30, c.dy + r * 0.26)
      ..lineTo(c.dx, c.dy + r * 0.46)
      ..lineTo(c.dx - r * 0.30, c.dy + r * 0.26)
      ..lineTo(c.dx - r * 0.34, c.dy - r * 0.18)
      ..close();
    canvas.drawPath(shield, Paint()..color = Colors.white);
    final Path star = Path();
    final double sr = r * 0.18;
    for (int i = 0; i < 10; i++) {
      final double rad = i.isEven ? sr : sr * 0.45;
      final double a = -math.pi / 2 + i * math.pi / 5;
      final Offset p =
          Offset(c.dx + rad * math.cos(a), c.dy + rad * math.sin(a));
      if (i == 0) {
        star.moveTo(p.dx, p.dy);
      } else {
        star.lineTo(p.dx, p.dy);
      }
    }
    star.close();
    canvas.drawPath(star, Paint()..color = BadgePalette.header);
  }

  @override
  bool shouldRepaint(_EmblemPainter oldDelegate) => false;
}

/// نقش guilloche خفيف (حلقات إهليلجية دوّارة) كعلامة مائية.
class _GuillochePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = BadgePalette.header.withValues(alpha: 0.10);
    final Offset c = size.center(Offset.zero);
    final Rect base = Rect.fromCenter(
      center: c,
      width: size.width * 0.9,
      height: size.width * 0.42,
    );
    for (int i = 0; i < 14; i++) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(i * math.pi / 14);
      canvas.translate(-c.dx, -c.dy);
      canvas.drawOval(base, stroke);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_GuillochePainter oldDelegate) => false;
}

class _QrView extends StatelessWidget {
  const _QrView({required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    // رمز أطول من سعة الإصدار أو بيانات تالفة ⇒ إطار واضح بدل إسقاط البطاقة.
    QrImage? image;
    try {
      image = QrImage(QrCode(6, QrErrorCorrectLevel.M)..addData(data));
    } catch (_) {
      image = null;
    }
    final QrImage? qr = image;
    if (qr == null) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFEFEFEF),
          border: Border.all(color: BadgePalette.header),
        ),
        child: Icon(
          Icons.qr_code_2,
          size: size * 0.6,
          color: BadgePalette.header,
        ),
      );
    }
    return CustomPaint(
      size: Size.square(size),
      painter: _QrPainter(qr),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.code);

  final QrImage code;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint dark = Paint()..color = const Color(0xFF000000);
    final Paint light = Paint()..color = const Color(0xFFFFFFFF);
    canvas.drawRect(Offset.zero & size, light);
    final double cell = size.width / code.moduleCount;
    for (int x = 0; x < code.moduleCount; x++) {
      for (int y = 0; y < code.moduleCount; y++) {
        if (code.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell * 1.02, cell * 1.02),
            dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.code != code;
}

class _Code128View extends StatelessWidget {
  const _Code128View({
    required this.data,
    required this.width,
    required this.height,
  });

  final String data;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    // إن تعذر ترميز النص (محرف غير مدعوم) نعرض خطوطاً بديلة ولا نُسقط الباج.
    bool encodable = true;
    try {
      Barcode.code128().make(data, width: width, height: height);
    } catch (_) {
      encodable = false;
    }
    if (!encodable) {
      return Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        color: Colors.white,
        child: Icon(
          Icons.linear_scale,
          size: height * 0.8,
          color: BadgePalette.ink,
        ),
      );
    }
    return CustomPaint(
      size: Size(width, height),
      painter: _Code128Painter(data, width, height),
    );
  }
}

class _Code128Painter extends CustomPainter {
  _Code128Painter(this.data, this.width, this.height);

  final String data;
  final double width;
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final Iterable<BarcodeElement> elements = Barcode.code128().make(
      data,
      width: size.width,
      height: size.height,
    );
    final Paint dark = Paint()..color = const Color(0xFF000000);
    for (final BarcodeElement e in elements) {
      if (e is BarcodeBar && e.black) {
        canvas.drawRect(
          Rect.fromLTWH(
            e.left.toDouble(),
            e.top.toDouble(),
            e.width.toDouble(),
            e.height.toDouble(),
          ),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Code128Painter oldDelegate) => oldDelegate.data != data;
}
