/// اختبارات طباعة البادجات: ترقيم صفحات ورقة A4 (10 للصفحة)، وبناء
/// الورقة والبطاقة المفردة بخط أميري المضمّن ينتج PDF صالحاً دون رمي.
/// أي عطل في تصميم البطاقة (شعار/رمز/صورة) كان يُسقط الطباعة كلها.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:student_hodor/features/badges/badge_print.dart';
import 'package:student_hodor/features/badges/badge_spec.dart';

/// PNG شفاف 1×1 لاختبار مسار الصورة داخل البطاقة المطبوعة.
const String _tinyPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

BadgeSpec _spec(int i) => BadgeSpec(
      schoolName: 'مدرسة النجاح',
      directorName: 'الأستاذ كريم',
      studentName: 'الطالب رقم $i',
      grade: 'السادس',
      section: 'أ',
      yearName: '2026-2027',
      code: 'HD-2026-${i.toString().padLeft(4, '0')}',
      sequence: i,
      photoBytes: i == 1 ? base64Decode(_tinyPng) : null,
    );

pw.Font _loadFont(String path) {
  final Uint8List raw = File(path).readAsBytesSync();
  return pw.Font.ttf(ByteData.sublistView(raw));
}

int _pageCount(Uint8List bytes) {
  final String raw = String.fromCharCodes(bytes);
  int countOf(String needle) => needle.allMatches(raw).length;
  return countOf('/Type /Page') +
      countOf('/Type/Page') -
      countOf('/Type /Pages') -
      countOf('/Type/Pages');
}

void main() {
  test('ترقيم ورقة A4: 10 بادجات للصفحة', () {
    expect(BadgePrint.pagesFor(0), 0);
    expect(BadgePrint.pagesFor(1), 1);
    expect(BadgePrint.pagesFor(10), 1);
    expect(BadgePrint.pagesFor(11), 2);
    expect(BadgePrint.pagesFor(25), 3);
  });

  test('ورقة A4 وباج مفرد بخط أميري: PDF صالح بعدد الصفحات الصحيح', () async {
    BadgePrint.registerFonts(
      _loadFont('assets/fonts/Amiri-Regular.ttf'),
      _loadFont('assets/fonts/Amiri-Bold.ttf'),
    );
    final List<BadgeSpec> specs =
        <BadgeSpec>[for (int i = 1; i <= 12; i++) _spec(i)];
    final Uint8List sheet = await BadgePrint.sheet(specs).save();
    expect(sheet, isNotEmpty);
    expect(_pageCount(sheet), 2);
    final Uint8List one = await BadgePrint.single(specs.first).save();
    expect(one, isNotEmpty);
    expect(_pageCount(one), 1);
  });
}
