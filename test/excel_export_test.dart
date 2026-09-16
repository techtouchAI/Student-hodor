/// اختبارات تصدير Excel — تحديداً ما اشتكى منه المستخدم في الميدان:
/// * اتجاه الأوراق داخل ملف xlsx **RTL فعلياً** (`rightToLeft="1"` في
///   `sheetView`) لا مجرد علم مضبوط في الذاكرة.
/// * الملف يبقى صالحاً بعد الترقيع (يُقرأ من جديد بالحزمة نفسها).
/// * لا عمود فارغاً بين اسم الطالب وأول يوم (كان اليوم الأول يُكتب في D).
/// * اسم الملف المصدَّر عربي وصفي بدل `hodor-<طابع زمني>.xlsx`.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/school_time.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/reports_service.dart';
import 'package:student_hodor/features/export/excel_builder.dart';

Future<AppDb> _seed() async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await db.setSetting('school_name', 'مدرسة النجاح');
  await db.setSetting('director_name', 'الأستاذ كريم');
  await db.into(db.academicYears).insert(
        const AcademicYearsCompanion(
          name: Value('2026-2027'),
          start: Value('2026-09-01'),
          end: Value('2027-06-30'),
          active: Value(true),
        ),
      );
  return db;
}

Future<(AppDb, AcademicYear, List<ExportScopeClass>)> _seededScope() async {
  final AppDb db = await _seed();
  final AcademicYear year = (await db.activeYear())!;
  final int classId = await db.into(db.schoolClasses).insert(
        SchoolClassesCompanion(
          yearId: Value(year.id),
          grade: const Value('السادس'),
          section: const Value('أ'),
        ),
      );
  final int studentId = await db.addStudent(
    yearId: year.id,
    classId: classId,
    fullName: 'علي حسن',
  );
  await db.upsertAttendance(
    yearId: year.id,
    classId: classId,
    studentId: studentId,
    date: '2026-09-02',
    status: AttendanceStatus.absent,
    source: AttendanceSource.manual,
  );
  final SchoolClass cls = await (db.select(db.schoolClasses)
        ..where((c) => c.id.equals(classId)))
      .getSingle();
  final List<Student> students = await (db.select(db.students)
        ..where((s) => s.classId.equals(classId)))
      .get();
  return (db, year, <ExportScopeClass>[ExportScopeClass(cls, students)]);
}

Future<List<int>> _buildExcel({
  bool includeDaily = true,
  bool includeSummary = true,
  bool includeLeaves = true,
}) async {
  final (AppDb db, AcademicYear year, List<ExportScopeClass> scope) =
      await _seededScope();
  try {
    final ExcelBuilder builder = ExcelBuilder(
      db: db,
      reports: ReportsService(db),
      schoolName: 'مدرسة النجاح',
      directorName: 'الأستاذ كريم',
      year: year,
      months: const <MonthKey>[MonthKey(2026, 9)],
      classes: scope,
      workWeekdays: SchoolTime.defaultWorkWeekdays,
      holidayKeys: const <String>{},
      includeDaily: includeDaily,
      includeSummary: includeSummary,
      includeLeaves: includeLeaves,
    );
    return await builder.build();
  } finally {
    await db.close();
  }
}

String _entry(Archive archive, String name) {
  final ArchiveFile f = archive.files.firstWhere((ArchiveFile x) => x.name == name);
  return utf8.decode(f.content as List<int>, allowMalformed: true);
}

void main() {
  group('ملف Excel المصدَّر', () {
    test('كل أوراقه RTL وتجميد العنوانين محفوظان داخل الـxlsx', () async {
      final List<int> bytes = await _buildExcel();
      final Archive archive = ZipDecoder().decodeBytes(bytes);
      final List<String> worksheets = archive.files
          .map((ArchiveFile f) => f.name)
          .where((String n) => n.startsWith('xl/worksheets/sheet'))
          .toList();
      expect(worksheets, isNotEmpty);
      for (final String name in worksheets) {
        final String xml = _entry(archive, name);
        expect(
          xml,
          contains('rightToLeft="1"'),
          reason: '$name يجب أن يُفتح من اليمين إلى اليسار',
        );
        expect(xml, contains('<pane '), reason: '$name يجب أن يجمّد العنوانين');
        // حزمة excel قد تُدرج `sheetViews` في آخر `worksheet` (موضع يخالف
        // مخطط OOXML ⇒ إكسل يتجاهله أو يطلب إصلاح الملف). الترقيع يعيد
        // كتابتها كتلةً واحدة قبل `sheetData`.
        expect(
          '<sheetViews'.allMatches(xml).length,
          1,
          reason: '$name: كتلة sheetViews واحدة لا مكرّرة',
        );
        expect(
          xml.indexOf('rightToLeft="1"'),
          lessThan(xml.indexOf('<sheetData')),
          reason: '$name: الاتجاه مُعلن قبل بيانات الخلايا (ترتيب المخطط)',
        );
      }
    });

    test('يبقى صالحاً بعد الترقيع: أسماء أوراق عربية وبلا Sheet1', () async {
      final List<int> bytes = await _buildExcel();
      final Excel decoded = Excel.decodeBytes(bytes);
      expect(decoded.tables.keys, contains('السادس-أ-أيلول 2026'));
      expect(decoded.tables.keys, contains('ملخص السنة'));
      expect(decoded.tables.keys, contains('الإجازات'));
      expect(
        decoded.tables.keys,
        isNot(contains('Sheet1')),
        reason: 'ورقة القالب الفارغة تصل للمستخدم تبويباً زائداً: '
            '`Excel.delete` ترفض حذف الورقة الوحيدة، فلا يصح استدعاؤها '
            'قبل إنشاء الكشوف',
      );
      // ثلاث أوراق حقيقية فقط — أي تبويب رابع يعني ورقة قالب باقية.
      expect(decoded.tables.length, 3);
    });

    test('تصدير بلا أوراق حقيقية يُبقي ورقة واحدة ولا يُنتج ملفاً تالفاً', () async {
      final List<int> bytes = await _buildExcel(
        includeDaily: false,
        includeSummary: false,
        includeLeaves: false,
      );
      final Excel decoded = Excel.decodeBytes(bytes);
      // ملف xlsx لا يصح بلا ورقة واحدة على الأقل ⇒ «Sheet1» تبقى هنا عمداً.
      expect(decoded.tables.length, 1);
      expect(bytes, isNotEmpty);
    });

    test('ترويسة الكشف اليومي: لا عمود فارغاً والمجاميع في مكانها', () async {
      final List<int> bytes = await _buildExcel();
      final Sheet daily = Excel.decodeBytes(bytes)['السادس-أ-أيلول 2026'];
      // الصف الثالث هو صف الترويسة.
      expect(daily.cell(CellIndex.indexByString('A3')).value?.toString(), 'م');
      expect(
        daily.cell(CellIndex.indexByString('B3')).value?.toString(),
        'اسم الطالب',
      );
      // اليوم الأول في العمود C مباشرة (كان D فيبقى C فارغاً).
      expect(daily.cell(CellIndex.indexByString('C3')).value?.toString(), '1');
      expect(daily.cell(CellIndex.indexByString('D3')).value?.toString(), '2');
      // المجاميع تلحق آخر يوم (31 ⇒ AG) بلا فراغ: AH..AL.
      expect(daily.cell(CellIndex.indexByString('AH3')).value?.toString(), 'غياب');
      expect(
        daily.cell(CellIndex.indexByString('AL3')).value?.toString(),
        'نسبة الحضور',
      );
      // بيانات الطالب: تسلسل واسم وحالة اليوم الثاني (2026-09-02 = غياب).
      expect(daily.cell(CellIndex.indexByString('A4')).value?.toString(), '1');
      expect(
        daily.cell(CellIndex.indexByString('B4')).value?.toString(),
        'علي حسن',
      );
      expect(daily.cell(CellIndex.indexByString('D4')).value?.toString(), 'غائب');
      expect(daily.cell(CellIndex.indexByString('AH4')).value?.toString(), '1');
    });

    test('ورقة الملخص تحمل عنواناً وترويسة في الصف الثالث', () async {
      final List<int> bytes = await _buildExcel(includeDaily: false);
      final Sheet summary = Excel.decodeBytes(bytes)['ملخص السنة'];
      expect(
        summary.cell(CellIndex.indexByString('A1')).value?.toString(),
        contains('ملخص الحضور والغياب'),
      );
      expect(summary.cell(CellIndex.indexByString('A3')).value?.toString(), 'م');
      expect(
        summary.cell(CellIndex.indexByString('C3')).value?.toString(),
        'اسم الطالب',
      );
      expect(
        summary.cell(CellIndex.indexByString('C4')).value?.toString(),
        'علي حسن',
      );
      expect(
        summary.cell(CellIndex.indexByString('F4')).value?.toString(),
        '1',
        reason: 'عمود الغياب في الملخص',
      );
    });

    test('اسم الملف المصدَّر عربي وصفي وبلا محارف ممنوعة', () {
      final String name = ExcelBuilder.exportFileName(
        schoolName: 'مدرسة النجاح',
        yearName: '2026-2027',
        months: const <MonthKey>[MonthKey(2026, 9)],
        now: DateTime(2026, 9, 16, 9, 5),
      );
      expect(name, endsWith('.xlsx'));
      expect(name, contains('كشف الحضور والغياب'));
      expect(name, contains('مدرسة النجاح'));
      expect(name, contains('أيلول 2026'));
      expect(name, isNot(contains('hodor')));
      expect(RegExp(r'[\\/:*?"<>|\r\n\t]').hasMatch(name), isFalse);
    });

    test('اسم الملف بلا مدرسة/بلا أشهر يبقى عربياً وآمناً', () {
      final String name = ExcelBuilder.exportFileName(
        schoolName: '',
        yearName: '',
        months: const <MonthKey>[],
      );
      expect(name, startsWith('كشف الحضور والغياب'));
      expect(name, endsWith('.xlsx'));
      expect(
        ExcelBuilder.sanitizeFileName(''),
        'تقرير الحضور',
        reason: 'لا اسم فارغاً يصل لنظام الملفات',
      );
      expect(
        ExcelBuilder.sanitizeFileName('a/b\\c:d*e?f"g<h>i|j'),
        isNot(contains('/')),
      );
    });
  });
}
