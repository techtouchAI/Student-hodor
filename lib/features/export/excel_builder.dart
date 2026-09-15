/// مولّد ملف Excel: كشف حضور شهري ملوّن (أخضر/أحمر/أصفر/برتقالي)
/// باتجاه RTL، مع مجاميع ونسب، وشهر واحد لكل ورقة + أوراق ملخّص وإجازات اختيارية.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide Column;
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
    required this.months,
    required this.classes,
    required this.workWeekdays,
    required this.holidayKeys,
    this.includeDaily = true,
    this.includeSummary = true,
    this.includeLeaves = true,
  });

  final AppDb db;
  final ReportsService reports;
  final String schoolName;
  final String directorName;
  final AcademicYear year;
  final List<MonthKey> months;
  final List<ExportScopeClass> classes;
  final Set<int> workWeekdays;
  final Set<String> holidayKeys;
  final bool includeDaily;
  final bool includeSummary;
  final bool includeLeaves;

  static const List<String> _statusAr = <String>[
    'حاضر',
    'غائب',
    'إجازة',
    'متأخر',
  ];

  final Set<String> _usedSheetNames = <String>{};

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

  /// اسم ورقة صالح: يستبدل المحارف الممنوعة في Excel ويقصّ بأمان (≤31).
  static String sanitizeSheetName(String raw) {
    String n = raw.replaceAll(RegExp(r'[\\/?*\[\]:]'), '-').trim();
    if (n.isEmpty) {
      n = 'sheet';
    }
    if (n.length > 27) {
      n = n.substring(0, 27);
    }
    return n;
  }

  /// اسم ورقة مميز داخل الملف نفسه (يلحق فاصلاً وعدّاداً عند التكرار).
  String _sheetName(String raw) {
    final String n = sanitizeSheetName(raw);
    String candidate = n;
    int i = 2;
    while (_usedSheetNames.contains(candidate)) {
      candidate = '$n-$i';
      i++;
    }
    _usedSheetNames.add(candidate);
    return candidate;
  }

  Future<Uint8List> build() async {
    final Excel excel = Excel.createExcel();
    excel.delete('Sheet1');
    if (includeDaily) {
      for (final MonthKey m in months) {
        for (final ExportScopeClass sc in classes) {
          final Sheet sheet = excel[
              _sheetName('${sc.cls.grade}-${sc.cls.section}-${m.label}')];
          sheet.isRTL = true;
          _writeHeader(sheet, sc, m);
          int row = 3;
          for (final Student s in sc.students) {
            final Map<String, int> byDate = <String, int>{
              for (final AttendanceRow r in await (db.select(db.attendanceRows)
                    ..where(
                      (a) => a.studentId.equals(s.id) & a.yearId.equals(year.id),
                    ))
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
              if (!m.isValidDay(day)) {
                continue;
              }
              final String key = SchoolTime.dateKey(DateTime(m.year, m.month, day));
              final int? status = byDate[key];
              final bool schoolDay = SchoolTime.isSchoolDay(
                DateTime(m.year, m.month, day),
                workWeekdays: workWeekdays,
                holidayKeys: holidayKeys,
              );
              final Data cell = sheet.cell(
                CellIndex.indexByColumnRow(columnIndex: 2 + day, rowIndex: row),
              );
              cell.value = TextCellValue(
                status == null ? (schoolDay ? '' : 'عطلة') : _statusAr[status],
              );
              cell.cellStyle = CellStyle(
                backgroundColorHex:
                    ExcelColor.fromHexString(_colorFor(status, schoolDay)),
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
                .value = IntCellValue(present);
            sheet
                .cell(CellIndex.indexByString('AL${row + 1}'))
                .value = IntCellValue(late);
            sheet
                .cell(CellIndex.indexByString('AM${row + 1}'))
                .value = DoubleCellValue(
              recorded == 0 ? 100 : (present + late) * 100 / recorded,
            );
            row++;
          }
        }
      }
    }
    if (includeSummary) {
      await _summarySheet(excel);
    }
    if (includeLeaves) {
      await _leavesSheet(excel);
    }
    final List<int>? bytes = excel.save();
    if (bytes == null) {
      throw StateError('excel save returned null');
    }
    return Uint8List.fromList(_freezePanes(bytes));
  }

  Future<void> _summarySheet(Excel excel) async {
    final Sheet sheet = excel[_sheetName('ملخص السنة')];
    sheet.isRTL = true;
    const List<String> head = <String>[
      'م',
      'الصف',
      'اسم الطالب',
      'حضور',
      'متأخر',
      'غياب',
      'إجازة',
      'نسبة الحضور',
    ];
    for (int i = 0; i < head.length; i++) {
      final Data c = sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      c.value = TextCellValue(head[i]);
      c.cellStyle = CellStyle(
        backgroundColorHex: ExcelColor.fromHexString(ExcelColors.header),
        fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
        bold: true,
        horizontalAlign: HorizontalAlign.Center,
      );
    }
    int row = 1;
    int index = 1;
    for (final ExportScopeClass sc in classes) {
      for (final Student s in sc.students) {
        final StatusTotals t = await reports.totalsForStudent(s.id, year.id);
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
            .value = IntCellValue(index++);
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
            .value = TextCellValue('${sc.cls.grade} ـ ${sc.cls.section}');
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row))
            .value = TextCellValue(s.fullName);
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row))
            .value = IntCellValue(t.present);
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row))
            .value = IntCellValue(t.late);
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: row))
            .value = IntCellValue(t.absent);
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: row))
            .value = IntCellValue(t.leave);
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row))
            .value = DoubleCellValue(t.ratePct);
        row++;
      }
    }
    sheet.setColumnWidth(2, 34.0);
  }

  Future<void> _leavesSheet(Excel excel) async {
    final Sheet sheet = excel[_sheetName('الإجازات')];
    sheet.isRTL = true;
    const List<String> head = <String>[
      'الطالب',
      'من',
      'إلى',
      'النوع',
      'السبب',
    ];
    for (int i = 0; i < head.length; i++) {
      final Data c = sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
      c.value = TextCellValue(head[i]);
      c.cellStyle = CellStyle(
        backgroundColorHex: ExcelColor.fromHexString(ExcelColors.header),
        fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
        bold: true,
        horizontalAlign: HorizontalAlign.Center,
      );
    }
    final List<Leave> leaves = await (db.select(db.leaves)
          ..where((l) => l.yearId.equals(year.id))
          ..orderBy(<OrderClauseGenerator<Leaves>>[
            (Leaves l) => OrderingTerm.desc(l.start),
          ]))
        .get();
    final Map<int, String> names = <int, String>{
      for (final Student s in await (db.select(db.students)
            ..where((x) => x.yearId.equals(year.id)))
          .get())
        s.id: s.fullName,
    };
    const List<String> types = <String>['مرضية', 'عرضية', 'طارئة'];
    int row = 1;
    for (final Leave l in leaves) {
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row))
          .value = TextCellValue(names[l.studentId] ?? '-');
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row))
          .value = TextCellValue(l.start);
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: row))
          .value = TextCellValue(l.end);
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: row))
          .value = TextCellValue(
        l.type >= 0 && l.type < types.length ? types[l.type] : '${l.type}',
      );
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: row))
          .value = TextCellValue(l.reason);
      row++;
    }
    sheet.setColumnWidth(0, 30.0);
  }

  void _writeHeader(Sheet sheet, ExportScopeClass sc, MonthKey m) {
    sheet.merge(
      CellIndex.indexByString('A1'),
      CellIndex.indexByString('AM1'),
    );
    final Data title = sheet.cell(CellIndex.indexByString('A1'));
    title.value = TextCellValue(
      '$schoolName — كشف حضور ${sc.cls.grade} ـ ${sc.cls.section} '
      '— ${m.label} — المدير: $directorName',
    );
    title.cellStyle = CellStyle(
      backgroundColorHex: ExcelColor.fromHexString(ExcelColors.header),
      fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
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
      final Data c = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: 2 + day, rowIndex: 2),
      );
      c.value = TextCellValue(m.isValidDay(day) ? '$day' : '');
      c.cellStyle = CellStyle(
        backgroundColorHex: ExcelColor.fromHexString(ExcelColors.header),
        fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
        bold: true,
        horizontalAlign: HorizontalAlign.Center,
      );
    }
    const Map<String, String> tails = <String, String>{
      'AI3': 'غياب',
      'AJ3': 'إجازة',
      'AK3': 'حضور',
      'AL3': 'متأخر',
      'AM3': 'نسبة الحضور',
    };
    tails.forEach((String ref, String label) {
      sheet.cell(CellIndex.indexByString(ref)).value = TextCellValue(label);
    });
    for (final String col in <String>['A3', 'B3', 'AI3', 'AJ3', 'AK3', 'AL3', 'AM3']) {
      sheet.cell(CellIndex.indexByString(col)).cellStyle = CellStyle(
            backgroundColorHex: ExcelColor.fromHexString(ExcelColors.header),
            fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
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
        final List<int> b = xml.codeUnits;
        out.addFile(ArchiveFile(f.name, b.length, b));
      } else {
        out.addFile(f);
      }
    }
    return ZipEncoder().encode(out)!;
  }
}
