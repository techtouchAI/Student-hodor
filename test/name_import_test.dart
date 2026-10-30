/// استيراد أسماء الطلاب من ملف (الملحق أ): قراءة TXT/DOCX، تنظيف، معاينة،
/// ثم كتابة واحدة داخل معاملة — بلا كتابة قبل التأكيد.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/name_import.dart';
import 'package:student_hodor/data/db.dart';

Uint8List _utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _utf16le(String s) => Uint8List.fromList(<int>[
      0xFF,
      0xFE,
      for (final int unit in s.codeUnits) ...<int>[unit & 0xFF, unit >> 8],
    ]);

/// «محمد علي» بترميز Windows-1256 (كما يكتبها Notepad العربي القديم).
final Uint8List _cp1256 = Uint8List.fromList(<int>[
  0xE3, 0xCD, 0xE3, 0xCF, 0x20, 0xDA, 0xE1, 0xED, //
]);

/// حاوية .docx مصغّرة: مستند واحد فقط — وهو ما يقرأه المحلّل فعلاً.
Uint8List _docx(String documentXml) {
  final List<int> bytes = utf8.encode(documentXml);
  final Archive archive = Archive()
    ..addFile(ArchiveFile('word/document.xml', bytes.length, bytes));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

String _cell(String t) => '<w:tc><w:p><w:r><w:t>$t</w:t></w:r></w:p></w:tc>';

String _row(List<String> cells) => '<w:tr>${cells.map(_cell).join()}</w:tr>';

String _par(String t) => '<w:p><w:r><w:t>$t</w:t></w:r></w:p>';

Future<({AppDb db, int yearId, int classId})> _seed() async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final int yearId = await db.into(db.academicYears).insert(
        const AcademicYearsCompanion(
          name: Value('2026-2027'),
          start: Value('2026-09-01'),
          end: Value('2027-06-30'),
          active: Value(true),
        ),
      );
  final int classId = await db.into(db.schoolClasses).insert(
        SchoolClassesCompanion(
          yearId: Value(yearId),
          grade: const Value('السادس'),
          section: const Value('أ'),
        ),
      );
  return (db: db, yearId: yearId, classId: classId);
}

void main() {
  test('نص UTF-8: الترقيم يُنزع، الترويسة والأسطر الفارغة تُتخطّى بالترتيب',
      () {
    final Uint8List bytes = Uint8List.fromList(<int>[
      0xEF, 0xBB, 0xBF, // BOM
      ...utf8.encode(
        'قائمة الطلاب\n'
        '\n'
        '1. أحمد علي حسن\n'
        '٢- بشار كريم\n'
        '(3) تيم محمد\n'
        '- سارة عبد الله\n',
      ),
    ]);
    final NameImportPreview p =
        parseNameFile(fileName: 'names.txt', bytes: bytes);

    expect(p.ok, isTrue);
    expect(
      p.values,
      <String>[
        'أحمد علي حسن',
        'بشار كريم',
        'تيم محمد',
        'سارة عبد الله',
      ],
      reason: 'الترتيب كما في الملف بعد نزع الترقيم',
    );
    expect(
      p.skipped.map((NameImportSkip s) => s.reason),
      containsAll(<String>['عنوان/ترويسة مستند', 'سطر فارغ']),
    );
  });

  test('Windows-1256 (Notepad العربي القديم) يُفكّ إلى عربية صحيحة', () {
    final NameImportPreview p =
        parseNameFile(fileName: 'old.txt', bytes: _cp1256);
    expect(p.values, <String>['محمد علي']);
    expect(decodeNameBytes(_cp1256), 'محمد علي');
  });

  test('UTF-16LE بعلامة ترتيب يُقرأ بلا رموز مشوّهة', () {
    final NameImportPreview p =
        parseNameFile(fileName: 'u16.txt', bytes: _utf16le('سارة علي\nليلى حسن'));
    expect(p.values, <String>['سارة علي', 'ليلى حسن']);
  });

  test('ملف .doc الثنائي يُرفض برسالة صريحة لا بقراءة عشوائية', () {
    final NameImportPreview p =
        parseNameFile(fileName: 'old.doc', bytes: _utf8Bytes('xxx'));
    expect(p.ok, isFalse);
    expect(p.error, contains('.docx'));
    expect(p.names, isEmpty);
  });

  test('Word: الفقرات والجدول مع استدلال عمود الاسم وتخطّي الترويسة', () {
    final String xml = '<w:document><w:body>'
        '${_par('قائمة طلاب السادس أ')}'
        '<w:tbl>'
        '${_row(<String>['ت', 'الاسم', 'ملاحظات'])}'
        '${_row(<String>['1', 'علي حسن كريم', '-'])}'
        '${_row(<String>['2', 'محمد جاسم', '-'])}'
        '</w:tbl>'
        '${_par('3. زينب كاظم')}'
        '</w:body></w:document>';
    final NameImportPreview p =
        parseNameFile(fileName: 'names.docx', bytes: _docx(xml));

    expect(p.ok, isTrue);
    expect(p.values, <String>['علي حسن كريم', 'محمد جاسم', 'زينب كاظم']);
    expect(p.source, contains('جدول'));
    // عمود الرقم والملاحظات لم يُقرأ كأسماء.
    expect(p.values, isNot(contains('1')));
    expect(p.values, isNot(contains('-')));
  });

  test('Word: جدول بلا عمود اسمي لا يُنتج أسماء وهمية', () {
    final String xml = '<w:document><w:body><w:tbl>'
        '${_row(<String>['1', '2', '3'])}'
        '${_row(<String>['4', '5', '6'])}'
        '</w:tbl></w:body></w:document>';
    final NameImportPreview p =
        parseNameFile(fileName: 'numbers.docx', bytes: _docx(xml));
    expect(p.ok, isTrue);
    expect(p.names, isEmpty);
    expect(p.skipped, isNotEmpty);
  });

  test('التطبيع: تشكيل وتطويل ومسافات زائدة، وحد 120 محرفاً', () {
    expect(cleanStudentName('  محمّــد   علي  '), 'محمد علي');
    expect(studentNameKey('أحمد'), studentNameKey('احمد'));
    final String tooLong = 'ا' * (maxStudentNameLength + 1);
    expect(isImportableName(tooLong), isFalse);
    expect(skipReasonFor(tooLong, cleaned: tooLong), 'أطول من 120 محرفاً');
    expect(stripLeadingNumbering('١. سارة'), 'سارة');
    expect(stripLeadingNumbering('#7 علي'), 'علي');
    expect(stripLeadingNumbering('- 2) محمد'), 'محمد');
  });

  test('المكرر داخل الملف يُسقَط والمتشابه يُعدّ مكرراً', () {
    final NameImportPreview p = parseTextNames(
      'أحمد علي\n'
      'احمد علي\n'
      'أحمــد  علي\n'
      'بشار كريم\n',
    );
    expect(p.values, <String>['أحمد علي', 'بشار كريم']);
    expect(
      p.skipped.where((NameImportSkip s) => s.reason == 'مكرر داخل الملف'),
      hasLength(2),
    );
  });

  test('الاستيراد: ترتيب وتسلسل وباجات، ثم تجاهل الموجودين عند التكرار',
      () async {
    final ({AppDb db, int yearId, int classId}) seed = await _seed();
    final AppDb db = seed.db;
    addTearDown(db.close);

    final StudentImportOutcome first = await db.importStudentNames(
      yearId: seed.yearId,
      classId: seed.classId,
      names: <String>['أحمد علي', 'بشار كريم', 'تيم محمد', '123'],
    );
    expect(first.added, 3);
    expect(first.skippedInvalid, 1, reason: 'السطر الرقمي ليس اسماً');

    final List<Student> kids = await (db.select(db.students)
          ..orderBy(<OrderClauseGenerator<Students>>[
            (Students s) => OrderingTerm.asc(s.seq),
          ]))
        .get();
    expect(
      <String>[for (final Student s in kids) s.fullName],
      <String>['أحمد علي', 'بشار كريم', 'تيم محمد'],
      reason: 'الترتيب كما في الملف عبر seq',
    );
    expect(<int>[for (final Student s in kids) s.seq], <int>[1, 2, 3]);
    expect(kids.every((Student s) => s.classId == seed.classId), isTrue);

    final int badges = (await db.select(db.badges).get()).length;
    expect(badges, 3, reason: 'لكل طالب باجه الأول');

    // إعادة الاستيراد نفسه: لا تكرار ولا حذف.
    final StudentImportOutcome second = await db.importStudentNames(
      yearId: seed.yearId,
      classId: seed.classId,
      names: <String>['أحمد علي', 'بشار كريم'],
    );
    expect(second.added, 0);
    expect(second.skippedExisting, 2);
    expect((await db.select(db.students).get()), hasLength(3));
  });

  test('الاستيراد إلى صف آخر لا يمسّ صفاً غيره', () async {
    final ({AppDb db, int yearId, int classId}) seed = await _seed();
    final AppDb db = seed.db;
    addTearDown(db.close);
    final int other = await db.into(db.schoolClasses).insert(
          SchoolClassesCompanion(
            yearId: Value(seed.yearId),
            grade: const Value('الخامس'),
            section: const Value('ب'),
          ),
        );
    await db.importStudentNames(
      yearId: seed.yearId,
      classId: seed.classId,
      names: <String>['أحمد علي'],
    );
    await db.importStudentNames(
      yearId: seed.yearId,
      classId: other,
      names: <String>['أحمد علي'],
    );
    final List<Student> kids = await db.select(db.students).get();
    expect(kids, hasLength(2), reason: 'السياق صف وشعبة، لا اسم فقط');
    expect(
      <int>{for (final Student s in kids) s.classId},
      <int>{seed.classId, other},
    );
  });
}
