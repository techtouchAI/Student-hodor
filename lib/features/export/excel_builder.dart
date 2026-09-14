/// مولّد ملف Excel: كشف حضور شهري ملوّن (أخضر/أحمر/أصفر/برتقالي)
/// باتجاه RTL، مع مجاميع ونسب، وشهر واحد لكل ورقة.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/reports_service.dart';

class ExcelColors {
  const ExcelColors._();
  static const String present = '#C6EFCE';
  static const String absent = '#FFC7CE';
  static const String leave = '#FFEB9C';
  static const String late = '#FCD5B4';
  static const String offDay = '#D9D9D9';
  static const String header = '#0D6E5F';
}

class ExportScopeClass {
  const ExportScopeClass(this.cls, this.students);

  final SchoolClass cls;
  final List<Student> students;
}

class ExcelBuilder {
  ExcelBuilder({
    required this.db,
    required this.reports,
    required this.schoolName,
    required this.directorName,
    required this.year,
    required this.yearNumber,
    required this.months,
    required this.classes,
    required this.workWeekdays,
    required this.holidayKeys,
  });

  final AppDb db;
  final ReportsService reports;
  final String schoolName;
  final String directorName;
  final AcademicYear year;
  final int yearNumber;
  final List<int> months;
  final List<ExportScopeClass> classes;
  final Set<int> workWeekdays;
  final Set<String> holidayKeys;

  static const List<String> _statusAr = <String>[
    'حاضر',
    'غائب',
    'إجازة',
    'متأخر',
  ];

  String _colorFor(int? status, bool schoolDay) {
    if (!schoolDay) {
      return ExcelColors.offDay;
    }
    switch (status) {
      case AttendanceStatus.present:
        return ExcelColors.present;
      case AttendanceStatus.absent:
        return ExcelColors.absent;
      case AttendanceStatus.leave:
        return ExcelColors.leave;
      case AttendanceStatus.late:
        return ExcelColors.late;
      default:
        return '#FFFFFF';
    }
  }

  Future<Uint8List> build() async {
    final Excel excel = Excel.createExcel();
    excel.delete('Sheet1');
    for (final int month in months) {
      for (final ExportScopeClass sc in classes) {
        final String sheetName =
            '${sc.cls.grade}-${sc.cls.section}-${SchoolTime.monthNames[month - 1]}';
        final Sheet sheet = excel[sheetName.substring(0, 30)];
        sheet.rtl = true;
        _writeHeader(sheet, sc, month);
        int row = 3;
        for (final Student s in sc.students) {
          final Map<String, int> byDate = <String, int>{
            for (final AttendanceRow r in await (db.select(db.attendanceRows)
                  ..where((a) => a.studentId.equals(s.id) & a.yearId.equals(year.id)))
                .get())
              r.date: r.status,
          };
          sheet
              .cell(CellIndex.indexByString('A${row + 1}'))
              .value = TextCellValue('${row - 2}');
          sheet
              .cell(CellIndex.indexByString('B${row + 1}'))
              .value = TextCellValue(s.fullName);
          int absent = 0;
          int leave = 0;
          int present = 0;
          int late = 0;
          for (int day = 1; day <= 31; day++) {
            final DateTime d = DateTime(yearNumber, month, day);
            if (d.month != month) {
              continue;
            }
            final String key = SchoolTime.dateKey(d);
            final int? status = byDate[key];
            final bool schoolDay = SchoolTime.isSchoolDay(
              d,
              workWeekdays: workWeekdays,
              holidayKeys: holidayKeys,
            );
            final Cell cell = sheet.cell(
              CellIndex.indexByColumnRow(columnIndex: 2 + day, rowIndex: row),
            );
            cell.value = TextCellValue(
              status == null ? (schoolDay ? '' : 'عطلة') : _statusAr[status],
            );
            cell.cellStyle = CellStyle(
              backgroundColorHex: _colorFor(status, schoolDay),
              horizontalAlign: HorizontalAlign.Center,
            );
            switch (status) {
              case AttendanceStatus.absent:
                absent++;
              case AttendanceStatus.leave:
                leave++;
              case AttendanceStatus.present:
                present++;
              case AttendanceStatus.late:
                late++;
            }
          }
          final int recorded = present + absent + leave + late;
          sheet
              .cell(CellIndex.indexByString('AI${row + 1}'))
              .value = IntCellValue(absent);
          sheet
              .cell(CellIndex.indexByString('AJ${row + 1}'))
              .value = IntCellValue(leave);
          sheet
              .cell(CellIndex.indexByString('AK${row + 1}'))
              .value = DoubleCellValue(
            recorded == 0 ? 100 : (present + late) * 100 / recorded,
          );
          row++;
        }
      }
    }
    final List<int>? bytes = excel.save();
    if (bytes == null) {
      throw StateError('excel save returned null');
    }
    return Uint8List.fromList(_freezePanes(bytes));
  }

  void _writeHeader(Sheet sheet, ExportScopeClass sc, int month) {
    sheet.merge(
      start: CellIndex.indexByString('A1'),
      end: CellIndex.indexByString('AK1'),
    );
    final Cell title = sheet.cell(CellIndex.indexByString('A1'));
    title.value = TextCellValue(
      '$schoolName — كشف حضور ${sc.cls.grade} ـ ${sc.cls.section} '
      '— ${SchoolTime.monthNames[month - 1]} $yearNumber — المدير: $directorName',
    );
    title.cellStyle = CellStyle(
      backgroundColorHex: ExcelColors.header,
      fontColorHex: '#FFFFFF',
      bold: true,
      horizontalAlign: HorizontalAlign.Center,
    );
    sheet
        .cell(CellIndex.indexByString('A3'))
        .value = TextCellValue('م');
    sheet
        .cell(CellIndex.indexByString('B3'))
        .value = TextCellValue('اسم الطالب');
    for (int day = 1; day <= 31; day++) {
      final Cell c = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: 2 + day, rowIndex: 2),
      );
      c.value = TextCellValue('$day');
      c.cellStyle = CellStyle(
        backgroundColorHex: ExcelColors.header,
        fontColorHex: '#FFFFFF',
        bold: true,
        horizontalAlign: HorizontalAlign.Center,
      );
    }
    sheet
        .cell(CellIndex.indexByString('AI3'))
        .value = TextCellValue('غياب');
    sheet
        .cell(CellIndex.indexByString('AJ3'))
        .value = TextCellValue('إجازة');
    sheet
        .cell(CellIndex.indexByString('AK3'))
        .value = TextCellValue('نسبة الحضور');
    for (final String col in <String>['A3', 'B3', 'AI3', 'AJ3', 'AK3']) {
      sheet.cell(CellIndex.indexByString(col)).cellStyle = CellStyle(
            backgroundColorHex: ExcelColors.header,
            fontColorHex: '#FFFFFF',
            bold: true,
            horizontalAlign: HorizontalAlign.Center,
          );
    }
    sheet.setColumnWidth(1, 34.0);
  }

  /// تجميد أول عمودين وصفّي العنوان عبر ترقيع sheetView داخل الـxlsx.
  List<int> _freezePanes(List<int> bytes) {
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final Archive out = Archive();
    for (final ArchiveFile f in archive) {
      if (f.name.startsWith('xl/worksheets/sheet') && f.name.endsWith('.xml')) {
        String xml = String.fromCharCodes(f.content as List<int>);
        const String pane =
            '<pane xSplit="2" ySplit="3" topLeftCell="C4" activePane="bottomRight" state="frozen"/>';
        if (xml.contains('<sheetView')) {
          if (RegExp(r'<sheetView[^>]*/>').hasMatch(xml)) {
            xml = xml.replaceFirstMapped(
              RegExp(r'<sheetView([^>]*)/>'),
              (Match m) => '<sheetView${m.group(1)}>$pane</sheetView>',
            );
          } else {
            xml = xml.replaceFirstMapped(
              RegExp(r'<sheetView([^>]*)>'),
              (Match m) => '<sheetView${m.group(1)}>$pane',
            );
          }
        }
        out.addFile(ArchiveFile(f.name, xml.length, xml.codeUnits));
      } else {
        out.addFile(f);
      }
    }
    return ZipEncoder().encode(out)!;
  }
}
