/// تصدير الغيابات فقط: ورقة «سجل الغيابات» تعرض لكل طالب غياباته وحدها
/// (بلا حضور ولا إجازات ولا تأخر)، تحترم الأشهر المحددة، ولها اسم ملف عربي —
/// في **الصيغتين**: ملف الإكسل ومستند PDF.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:student_hodor/core/school_time.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/reports_service.dart';
import 'package:student_hodor/features/export/excel_builder.dart';
import 'package:student_hodor/features/export/pdf_report.dart';

/// غيابان في شهرين مختلفين + حضور + تأخر: في ورقة الغيابات يظهر الغيابان فقط.
Future<(AppDb, AcademicYear, List<ExportScopeClass>)> _seed() async {
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
    source: AttendanceSource.autoClose,
  );
  await db.upsertAttendance(
    yearId: year.id,
    classId: classId,
    studentId: studentId,
    date: '2026-09-03',
    status: AttendanceStatus.present,
    source: AttendanceSource.scan,
    arrivalTime: '07:50',
  );
  await db.upsertAttendance(
    yearId: year.id,
    classId: classId,
    studentId: studentId,
    date: '2026-09-06',
    status: AttendanceStatus.late,
    source: AttendanceSource.scan,
    arrivalTime: '08:20',
  );
  await db.upsertAttendance(
    yearId: year.id,
    classId: classId,
    studentId: studentId,
    date: '2026-10-05',
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

Future<List<int>> _build({required List<MonthKey> months}) async {
  final (AppDb db, AcademicYear year, List<ExportScopeClass> scope) =
      await _seed();
  try {
    final ExcelBuilder builder = ExcelBuilder(
      db: db,
      reports: ReportsService(db),
      schoolName: 'مدرسة النجاح',
      directorName: 'الأستاذ كريم',
      year: year,
      months: months,
      classes: scope,
      workWeekdays: SchoolTime.defaultWorkWeekdays,
      holidayKeys: const <String>{},
      includeDaily: false,
      includeSummary: false,
      includeLeaves: false,
      includeAbsences: true,
    );
    return await builder.build();
  } finally {
    await db.close();
  }
}

void main() {
  group('ورقة الغيابات فقط', () {
    test('تعرض غيابات الطالب وحدها وبلا الحالات الأخرى', () async {
      final List<int> bytes = await _build(months: const <MonthKey>[]);
      final Excel decoded = Excel.decodeBytes(bytes);
      expect(decoded.tables.keys, contains('سجل الغيابات'));
      final Sheet sheet = decoded['سجل الغيابات'];
      // العنوان والترويسة في موضعيهما الموحدين (صف 1 وصف 3).
      expect(
        sheet.cell(CellIndex.indexByString('A1')).value?.toString(),
        contains('غياب الطلاب'),
      );
      expect(
        sheet.cell(CellIndex.indexByString('D3')).value?.toString(),
        'تاريخ الغياب',
      );
      // الغيابان مرتبان بالتاريخ، والحضور والتأخر لا يظهران أبداً.
      expect(
        sheet.cell(CellIndex.indexByString('D4')).value?.toString(),
        '2026-09-02',
      );
      expect(
        sheet.cell(CellIndex.indexByString('D5')).value?.toString(),
        '2026-10-05',
      );
      // طريقة التسجيل محفوظة من السجل.
      expect(
        sheet.cell(CellIndex.indexByString('F4')).value?.toString(),
        'إقفال تلقائي',
      );
      expect(
        sheet.cell(CellIndex.indexByString('F5')).value?.toString(),
        'يدوي',
      );
      // الإجمالي العام في الصف التالي لآخر غياب.
      expect(sheet.cell(CellIndex.indexByString('D6')).value?.toString(), '2');
    });

    test('الأشهر المحددة ترشّح الغيابات', () async {
      final List<int> bytes =
          await _build(months: const <MonthKey>[MonthKey(2026, 9)]);
      final Sheet sheet = Excel.decodeBytes(bytes)['سجل الغيابات'];
      expect(
        sheet.cell(CellIndex.indexByString('D4')).value?.toString(),
        '2026-09-02',
      );
      // غياب تشرين الأول خارج الشهر المحدد، والصف التالي هو الإجمالي مباشرة.
      expect(sheet.cell(CellIndex.indexByString('D5')).value?.toString(), '1');
    });

    test('اسم الملف عربي ويصف النطاق', () {
      final String name = ExcelBuilder.absencesFileName(
        schoolName: 'مدرسة النجاح',
        yearName: '2026-2027',
        months: const <MonthKey>[],
        now: DateTime(2026, 9, 16, 9, 5),
      );
      expect(name, contains('سجل الغيابات'));
      expect(name, contains('مدرسة النجاح'));
      expect(name, contains('السنة كاملة'));
      expect(name, endsWith('.xlsx'));
      expect(
        ExcelBuilder.absencesFileName(
          schoolName: 'مدرسة النجاح',
          yearName: '2026-2027',
          months: const <MonthKey>[MonthKey(2026, 9)],
          now: DateTime(2026, 9, 16, 9, 5),
        ),
        contains('أيلول 2026'),
      );
    });
  });

  group('PDF الغيابات فقط', () {
    test('يبني مستنداً بصفحة على الأقل غياباتٍ فقط بلا كشوف ولا ملخص', () async {
      final (AppDb db, AcademicYear year, List<ExportScopeClass> scope) =
          await _seed();
      addTearDown(db.close);
      final PdfReport report = PdfReport(
        db: db,
        reports: ReportsService(db),
        schoolName: 'مدرسة النجاح',
        directorName: 'الأستاذ كريم',
        year: year,
        months: const <MonthKey>[],
        classes: scope,
        workWeekdays: SchoolTime.defaultWorkWeekdays,
        holidayKeys: const <String>{},
        font: _loadFont('assets/fonts/Amiri-Regular.ttf'),
        fontBold: _loadFont('assets/fonts/Amiri-Bold.ttf'),
        includeDaily: false,
        includeSummary: false,
        includeAbsences: true,
      );
      final pw.Document doc = await report.build();
      final Uint8List bytes = await doc.save();
      expect(_pageCount(bytes), greaterThanOrEqualTo(1));
    });

    test('الترشيح بشهر محدد يبني مستنداً صالحاً أيضاً', () async {
      final (AppDb db, AcademicYear year, List<ExportScopeClass> scope) =
          await _seed();
      addTearDown(db.close);
      final PdfReport report = PdfReport(
        db: db,
        reports: ReportsService(db),
        schoolName: 'مدرسة النجاح',
        directorName: 'الأستاذ كريم',
        year: year,
        months: const <MonthKey>[MonthKey(2026, 9)],
        classes: scope,
        workWeekdays: SchoolTime.defaultWorkWeekdays,
        holidayKeys: const <String>{},
        font: _loadFont('assets/fonts/Amiri-Regular.ttf'),
        fontBold: _loadFont('assets/fonts/Amiri-Bold.ttf'),
        includeDaily: false,
        includeSummary: false,
        includeAbsences: true,
      );
      final Uint8List bytes = await (await report.build()).save();
      expect(_pageCount(bytes), greaterThanOrEqualTo(1));
    });
  });
}

pw.Font _loadFont(String path) {
  final Uint8List raw = File(path).readAsBytesSync();
  return pw.Font.ttf(ByteData.sublistView(raw));
}

/// عدّاد صفحات مطابق لما في اختبار سجل الطالب — يؤكد مستنداً غير فارغ.
int _pageCount(Uint8List bytes) {
  final String raw = String.fromCharCodes(bytes);
  int countOf(String needle) => needle.allMatches(raw).length;
  return countOf('/Type /Page') +
      countOf('/Type/Page') -
      countOf('/Type /Pages') -
      countOf('/Type/Pages');
}
