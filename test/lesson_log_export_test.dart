/// تصدير **سجل الحصص التفصيلي وحده** في الصيغتين — اختبار انحدار لخلل
/// «زر التوليد معطّل عندما يكون سجل الحصص هو القسم الوحيد المختار».
///
/// يثبت أن اختيار هذا القسم وحده:
///  * يُنتج ملفاً صالحاً في Excel وPDF،
///  * يحوي بيانات السجل الفعلية (الاسم/التاريخ/الحصة/وقت الحصة/الحالة/الوقت/
///    المصدر) بترتيب ثابت (الطالب ثم التاريخ ثم رقم الحصة)،
///  * بلا أوراق أو أقسام أخرى لم يطلبها المستخدم،
///  * ويعالج سجلاً فارغاً برسالة صريحة لا بملف يبدو تالفاً.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:student_hodor/core/lesson.dart';
import 'package:student_hodor/core/school_time.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/reports_service.dart';
import 'package:student_hodor/features/export/excel_builder.dart';
import 'package:student_hodor/features/export/pdf_report.dart';

/// سنة + صف + طالبان + جدول حصص بأسماء وأوقات مخصّصة.
///
/// الأسماء مختارة بحيث يكون ترتيبها الأبجدي معلوماً («أحمد» قبل «زيد») فلا
/// يعتمد الاختبار على تفاصيل مقارنة المحارف العربية في Dart.
Future<({AppDb db, AcademicYear year, List<ExportScopeClass> scope})>
    _seed({required bool withRecords}) async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await db.setSetting('school_name', 'مدرسة النجاح');
  await db.setSetting('director_name', 'الأستاذ كريم');
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
  final int ahmed = await db.addStudent(
    yearId: yearId,
    classId: classId,
    fullName: 'أحمد علي',
  );
  final int zaid = await db.addStudent(
    yearId: yearId,
    classId: classId,
    fullName: 'زيد كريم',
  );
  // أسماء وأوقات مخصّصة: الاختبار يثبت أن الملف يأخذها من جدول الحصص
  // الحالي لا من قالب ثابت.
  final List<LessonWindow> lessons = await db.lessonWindows();
  await db.saveLessons(<LessonWindow>[
    for (final LessonWindow l in lessons)
      LessonWindow(
        id: l.id,
        slot: l.slot,
        name: 'حصة الاختبار ${l.slot}',
        start: l.start,
        end: l.end,
      ),
  ]);
  if (withRecords) {
    await db.upsertAttendance(
      yearId: yearId,
      classId: classId,
      studentId: ahmed,
      date: '2026-09-01',
      lessonId: lessons[0].id,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
      arrivalTime: '08:02',
    );
    await db.upsertAttendance(
      yearId: yearId,
      classId: classId,
      studentId: ahmed,
      date: '2026-09-02',
      lessonId: lessons[2].id,
      status: AttendanceStatus.absent,
      source: AttendanceSource.autoClose,
    );
    await db.upsertAttendance(
      yearId: yearId,
      classId: classId,
      studentId: zaid,
      date: '2026-09-01',
      lessonId: lessons[1].id,
      status: AttendanceStatus.late,
      source: AttendanceSource.scan,
      arrivalTime: '08:55',
    );
  }
  final AcademicYear year = (await db.activeYear())!;
  final SchoolClass cls = await (db.select(db.schoolClasses)
        ..where((c) => c.id.equals(classId)))
      .getSingle();
  final List<Student> students = await (db.select(db.students)
        ..where((s) => s.classId.equals(classId))
        ..orderBy(<OrderClauseGenerator<Students>>[
          (Students s) => OrderingTerm.asc(s.fullName),
        ]))
      .get();
  return (
    db: db,
    year: year,
    scope: <ExportScopeClass>[ExportScopeClass(cls, students)],
  );
}

/// ملف Excel بسجل الحصص وحده — بلا كشوف ولا ملخص ولا إجازات ولا غيابات.
Future<List<int>> _buildLessonLogExcel({required bool withRecords}) async {
  final ({AppDb db, AcademicYear year, List<ExportScopeClass> scope}) seed =
      await _seed(withRecords: withRecords);
  try {
    return await ExcelBuilder(
      db: seed.db,
      reports: ReportsService(seed.db),
      schoolName: 'مدرسة النجاح',
      directorName: 'الأستاذ كريم',
      year: seed.year,
      // بلا أشهر محددة ⇒ النطاق السنة كلها (سلوك «الغيابات» نفسه).
      months: const <MonthKey>[],
      classes: seed.scope,
      workWeekdays: SchoolTime.defaultWorkWeekdays,
      holidayKeys: const <String>{},
      includeDaily: false,
      includeSummary: false,
      includeLeaves: false,
      includeAbsences: false,
      includeLessonLog: true,
    ).build();
  } finally {
    await seed.db.close();
  }
}

Future<Uint8List> _buildLessonLogPdf({required bool withRecords}) async {
  final ({AppDb db, AcademicYear year, List<ExportScopeClass> scope}) seed =
      await _seed(withRecords: withRecords);
  try {
    final PdfReport report = PdfReport(
      db: seed.db,
      reports: ReportsService(seed.db),
      schoolName: 'مدرسة النجاح',
      directorName: 'الأستاذ كريم',
      year: seed.year,
      months: const <MonthKey>[],
      classes: seed.scope,
      workWeekdays: SchoolTime.defaultWorkWeekdays,
      holidayKeys: const <String>{},
      font: _font('assets/fonts/Amiri-Regular.ttf'),
      fontBold: _font('assets/fonts/Amiri-Bold.ttf'),
      includeDaily: false,
      includeSummary: false,
      includeAbsences: false,
      includeLessonLog: true,
    );
    final Uint8List bytes = await (await report.build()).save();
    return bytes;
  } finally {
    await seed.db.close();
  }
}

pw.Font _font(String path) {
  final Uint8List raw = File(path).readAsBytesSync();
  return pw.Font.ttf(ByteData.sublistView(raw));
}

/// عدّاد صفحات PDF (كما في اختبارات التصدير القائمة) — يثبت مستنداً غير فارغ.
int _pageCount(Uint8List bytes) {
  final String raw = String.fromCharCodes(bytes);
  int countOf(String needle) => needle.allMatches(raw).length;
  return countOf('/Type /Page') +
      countOf('/Type/Page') -
      countOf('/Type /Pages') -
      countOf('/Type/Pages');
}

String? _cell(Sheet sheet, String ref) =>
    sheet.cell(CellIndex.indexByString(ref)).value?.toString();

void main() {
  group('Excel: سجل الحصص وحده', () {
    test('ورقة واحدة فقط تحمل بيانات السجل بالترتيب والأوقات الصحيحة', () async {
      final Excel decoded = Excel.decodeBytes(
        await _buildLessonLogExcel(withRecords: true),
      );
      expect(
        decoded.tables.keys.toSet(),
        <String>{'سجل الحصص'},
        reason: 'لا كشوف ولا ملخص ولا إجازات ولا غيابات، ولا ورقة قالب',
      );
      final Sheet sheet = decoded['سجل الحصص'];
      expect(_cell(sheet, 'A1'), contains('سجل الحصص التفصيلي'));
      expect(_cell(sheet, 'A3'), 'م');
      expect(_cell(sheet, 'F3'), 'الحصة');
      expect(_cell(sheet, 'G3'), 'وقت الحصة');
      expect(_cell(sheet, 'I3'), 'وقت الوصول');
      expect(_cell(sheet, 'J3'), 'المصدر');

      // الصف الرابع: أحمد / 2026-09-01 / الحصة الأولى.
      expect(_cell(sheet, 'C4'), 'أحمد علي');
      expect(_cell(sheet, 'D4'), '2026-09-01');
      expect(_cell(sheet, 'E4'), 'الثلاثاء');
      expect(_cell(sheet, 'F4'), 'حصة الاختبار 1');
      expect(_cell(sheet, 'G4'), '08:00–08:45');
      expect(_cell(sheet, 'H4'), 'حاضر');
      expect(_cell(sheet, 'I4'), '08:02');
      expect(_cell(sheet, 'J4'), 'مسح');

      // الصف الخامس: أحمد / 2026-09-02 / الحصة الثالثة.
      expect(_cell(sheet, 'C5'), 'أحمد علي');
      expect(_cell(sheet, 'D5'), '2026-09-02');
      expect(_cell(sheet, 'F5'), 'حصة الاختبار 3');
      expect(_cell(sheet, 'G5'), '09:40–10:25');
      expect(_cell(sheet, 'H5'), 'غائب');
      expect(_cell(sheet, 'J5'), 'إقفال تلقائي');

      // الصف السادس: زيد / 2026-09-01 / الحصة الثانية (ترتيب الاسم ثم التاريخ).
      expect(_cell(sheet, 'C6'), 'زيد كريم');
      expect(_cell(sheet, 'D6'), '2026-09-01');
      expect(_cell(sheet, 'F6'), 'حصة الاختبار 2');
      expect(_cell(sheet, 'H6'), 'متأخر');
      expect(_cell(sheet, 'I6'), '08:55');
      expect(sheet.maxRows, 6, reason: 'ثلاثة سجلات فقط: عنوان + ترويسة + 3');
      expect(sheet.maxColumns, 10, reason: 'أعمدة السجل عشرة، لا ورقة أخرى');
    });

    test('سجل فارغ: رسالة صريحة بدل ورقة تبدو تالفة', () async {
      final Excel decoded = Excel.decodeBytes(
        await _buildLessonLogExcel(withRecords: false),
      );
      expect(decoded.tables.keys.toSet(), <String>{'سجل الحصص'});
      final Sheet sheet = decoded['سجل الحصص'];
      expect(_cell(sheet, 'A4'), 'لا تسجيلات في النطاق المحدد');
      expect(sheet.maxRows, 4, reason: 'عنوان + ترويسة + رسالة، بلا بيانات وهمية');
      expect(sheet.maxColumns, 10);
    });
  });

  group('PDF: سجل الحصص وحده', () {
    test('مستند غير فارغ بسجل الحصص وحده', () async {
      final Uint8List bytes = await _buildLessonLogPdf(withRecords: true);
      expect(_pageCount(bytes), greaterThanOrEqualTo(1));
    });

    test('مستند غير فارغ بسجل فارغ', () async {
      final Uint8List bytes = await _buildLessonLogPdf(withRecords: false);
      expect(_pageCount(bytes), greaterThanOrEqualTo(1));
    });
  });
}
