/// عرض الباج على الشاشة (معاينة قبل الطباعة).
library;

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
    return Container(
      width: width,
      height: _height,
      decoration: BoxDecoration(
        color: BadgePalette.background,
        borderRadius: BorderRadius.circular(width * 0.05),
        border: Border.all(color: BadgePalette.headerDark, width: 1.2),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x22000000), blurRadius: 6, offset: Offset(0, 3)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
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
                colors: <Color>[BadgePalette.headerDark, BadgePalette.header],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Column(
              children: <Widget>[
                Text(
                  spec.schoolName,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: width * 0.062,
                  ),
                ),
                SizedBox(height: width * 0.012),
                Text(
                  'المدير: ${spec.directorName}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: width * 0.042),
                ),
              ],
            ),
          ),
          Container(height: width * 0.02, color: BadgePalette.gold),
          Expanded(
            child: Padding(
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
                  Text(spec.classLine, style: lineStyle),
                  Text(spec.yearLine, style: lineStyle),
                  const Spacer(),
                  _QrView(data: spec.code, size: width * 0.30),
                  SizedBox(height: width * 0.02),
                  _Code128View(data: spec.code, width: width * 0.8, height: width * 0.11),
                  Text(
                    spec.seqLine,
                    style: TextStyle(fontSize: width * 0.045, color: BadgePalette.ink),
                  ),
                ],
              ),
            ),
          ),
        ],
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
          borderRadius: BorderRadius.circular(w * 0.03),
          border: Border.all(color: BadgePalette.header),
        ),
        child: Icon(Icons.person, size: w * 0.2, color: BadgePalette.header),
      );
    }
    return Container(
      width: w * 0.34,
      height: w * 0.42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(w * 0.03),
        border: Border.all(color: BadgePalette.header),
        image: DecorationImage(
          image: MemoryImage(Uint8List.fromList(bytes)),
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _QrView extends StatelessWidget {
  const _QrView({required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final QrCode code = QrCode(6, QrErrorCorrectLevel.M)..addData(data);
    code.make();
    return CustomPaint(
      size: Size.square(size),
      painter: _QrPainter(code),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.code);

  final QrCode code;

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
  Widget build(BuildContext context) => CustomPaint(
        size: Size(width, height),
        painter: _Code128Painter(data, width, height),
      );
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
      Uint8List.fromList(data.codeUnits),
      width: size.width.toInt(),
      height: size.height.toInt(),
    );
    final Paint dark = Paint()..color = const Color(0xFF000000);
    for (final BarcodeElement e in elements) {
      if (e is BarcodeBar && e.color) {
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
