/// سجل الطالب الكامل: النطاق من بداية السنة حتى اليوم، محتوى Excel،
/// بناء PDF، واسم الملف — كلها من مصدر الحقيقة [StudentRecord] نفسه.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:student_hodor/core/school_time.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/reports_service.dart';
import 'package:student_hodor/features/export/excel_builder.dart';
import 'package:student_hodor/features/export/student_record_pdf.dart';

Future<(AppDb, AcademicYear, Student, String)> _seed() async {
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
    source: AttendanceSource.manual,
  );
  await db.upsertAttendance(
    yearId: year.id,
    classId: classId,
    studentId: studentId,
    date: '2026-09-03',
    status: AttendanceStatus.present,
    source: AttendanceSource.scan,
  );
  final Student student = (await db.studentById(studentId))!;
  return (db, year, student, 'السادس ـ أ');
}

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
  test('النطاق من بداية السنة حتى اليوم والحالات في مواضعها', () async {
    final (AppDb db, AcademicYear year, Student student, _) = await _seed();
    addTearDown(db.close);
    final StudentRecord record = await ReportsService(db).studentRecord(
      studentId: student.id,
      year: year,
      workWeekdays: SchoolTime.defaultWorkWeekdays,
      holidayKeys: <String>{},
      today: DateTime(2026, 9, 5),
    );
    expect(record.from, '2026-09-01');
    expect(record.to, '2026-09-05');
    expect(record.days.length, 5);
    expect(record.days[1].status, AttendanceStatus.absent);
    expect(record.days[2].status, AttendanceStatus.present);
    expect(record.days[0].status, isNull);
    expect(record.totals.absent, 1);
    expect(record.totals.present, 1);
  });

  test('اليوم بعد نهاية السنة يُكبَت بنهايتها', () async {
    final (AppDb db, AcademicYear year, Student student, _) = await _seed();
    addTearDown(db.close);
    final StudentRecord record = await ReportsService(db).studentRecord(
      studentId: student.id,
      year: year,
      workWeekdays: SchoolTime.defaultWorkWeekdays,
      holidayKeys: <String>{},
      today: DateTime(2028, 1, 1),
    );
    expect(record.to, '2027-06-30');
    expect(record.days.first.dateKey, '2026-09-01');
    expect(record.days.last.dateKey, '2027-06-30');
  });

  test('Excel السجل: أيام ملونة وإحصائيات وRTL', () async {
    final (AppDb db, AcademicYear year, Student student, String classTitle) =
        await _seed();
    addTearDown(db.close);
    final ExcelBuilder builder = ExcelBuilder.studentRecord(
      db: db,
      reports: ReportsService(db),
      schoolName: 'مدرسة النجاح',
      directorName: 'الأستاذ كريم',
      year: year,
      workWeekdays: SchoolTime.defaultWorkWeekdays,
      holidayKeys: <String>{},
    );
    final Uint8List bytes = await builder.buildStudentRecord(
      student: student,
      classTitle: classTitle,
      today: DateTime(2026, 9, 5),
    );
    final Sheet sheet = Excel.decodeBytes(bytes)['سجل الطالب'];
    expect(
      sheet.cell(CellIndex.indexByString('A1')).value?.toString(),
      contains('علي حسن'),
    );
    expect(
      sheet.cell(CellIndex.indexByString('B4')).value?.toString(),
      '2026-09-01',
    );
    expect(
      sheet.cell(CellIndex.indexByString('D4')).value?.toString(),
      'لم يسجل',
    );
    expect(
      sheet.cell(CellIndex.indexByString('D5')).value?.toString(),
      'غائب',
    );
    expect(
      sheet.cell(CellIndex.indexByString('D6')).value?.toString(),
      'حاضر',
    );
    // 2026-09-04 جمعة و09-05 سبت: خارج أيام الدوام الافتراضية.
    expect(
      sheet.cell(CellIndex.indexByString('D7')).value?.toString(),
      'عطلة',
    );
    expect(
      sheet.cell(CellIndex.indexByString('D8')).value?.toString(),
      'عطلة',
    );
    expect(
      sheet.cell(CellIndex.indexByString('B11')).value?.toString(),
      'إجمالي الغياب',
    );
    expect(
      sheet.cell(CellIndex.indexByString('C11')).value?.toString(),
      '1',
    );
    expect(
      sheet.cell(CellIndex.indexByString('C15')).value?.toString(),
      '50.0',
    );
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    bool rtlFound = false;
    for (final ArchiveFile f in archive) {
      if (f.name.startsWith('xl/worksheets/sheet') &&
          f.name.endsWith('.xml')) {
        final String xml = String.fromCharCodes(f.content as List<int>);
        if (xml.contains('rightToLeft="1"')) {
          rtlFound = true;
        }
      }
    }
    expect(rtlFound, isTrue);
  });

  test('PDF السجل يُبنى صفحات صالحة', () async {
    final (AppDb db, AcademicYear year, Student student, String classTitle) =
        await _seed();
    addTearDown(db.close);
    final StudentRecordPdf record = StudentRecordPdf(
      reports: ReportsService(db),
      schoolName: 'مدرسة النجاح',
      directorName: 'الأستاذ كريم',
      year: year,
      student: student,
      classTitle: classTitle,
      workWeekdays: SchoolTime.defaultWorkWeekdays,
      holidayKeys: <String>{},
      font: _loadFont('assets/fonts/Amiri-Regular.ttf'),
      fontBold: _loadFont('assets/fonts/Amiri-Bold.ttf'),
      today: DateTime(2026, 9, 5),
    );
    final Uint8List bytes = await (await record.build()).save();
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(_pageCount(bytes), greaterThanOrEqualTo(1));
  });

  test('اسم ملف السجل عربي وآمن', () {
    final String name = ExcelBuilder.recordFileName(
      studentName: 'علي حسن',
      yearName: '2026-2027',
      now: DateTime(2026, 9, 17, 10, 30),
    );
    expect(name, contains('سجل الطالب'));
    expect(name, contains('علي حسن'));
    expect(name.endsWith('.xlsx'), isTrue);
    final String evil = ExcelBuilder.recordFileName(
      studentName: 'a/b',
      yearName: '2026-2027',
      now: DateTime(2026, 9, 17),
    );
    expect(evil, isNot(contains('/')));
  });
}
