/// مولّد ملف Excel: كشف حضور شهري ملوّن (أخضر/أحمر/أصفر/برتقالي)
/// باتجاه RTL، مع مجاميع ونسب، وشهر واحد لكل ورقة + أوراق ملخّص وإجازات اختيارية.
///
/// الاتجاه من اليمين إلى اليسار يُفرض **ثلاث مرات**:
/// 1. `sheet.isRTL = true` (تكتبه الحزمة في `sheetView`).
/// 2. ترقيع صريح لـ`rightToLeft="1"` في كل `sheetView` بعد الحفظ
///    ([_patchSheets]) حتى لا يتوقف الأمر على سلوك نسخة الحزمة — فالملف كان
///    يُفتح أحياناً باتجاه إنكليزي (LTR) فيظهر ترتيب الأعمدة معكوساً.
/// 3. اتجاه قراءة RTL صريح (`readingOrder="2"`) على كل نمط محاذاته يمين
///    ([_patchStylesRtl])، فالمحاذاة وحدها لا تكفي لدقة اتجاه الأسماء.
///
/// وكذلك محاذاة خلايا النص (الاسم/الصف) تُضبط صراحةً `Right` فلا تعتمد على
/// افتراض Excel، وأسماء الملفات المصدّرة عربية (انظر [exportFileName]).
library;

import 'dart:convert';

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

  /// سجل طالب واحد (من ملف الطالب): الأشهر والصفوف لا معنى لها هنا —
  /// يُبنى عبر [buildStudentRecord] لا [build].
  ExcelBuilder.studentRecord({
    required this.db,
    required this.reports,
    required this.schoolName,
    required this.directorName,
    required this.year,
    required this.workWeekdays,
    required this.holidayKeys,
  })  : months = const <MonthKey>[],
        classes = const <ExportScopeClass>[],
        includeDaily = false,
        includeSummary = false,
        includeLeaves = false;

  static const List<String> _statusAr = <String>[
    'حاضر',
    'غائب',
    'إجازة',
    'متأخر',
  ];

  // ---------------- تخطيط الأعمدة ----------------
  //
  // كان اليوم الأول يُكتب في العمود D (`columnIndex: 2 + day`) فيبقى العمود C
  // فارغاً بين اسم الطالب وأول يوم — عمود ضائع في منتصف كشف عربي. الأرقام
  // الآن مشتقة من ثابت واحد لا مكتوبة يدوياً في كل موضع.

  /// عمود التسلسل «م» (A).
  static const int _indexColumn = 0;

  /// عمود اسم الطالب (B).
  static const int _nameColumn = 1;

  /// عمود يوم `day` (1..31) ⇒ C..AG.
  static int _dayColumn(int day) => _nameColumn + day;

  static const int _absentColumn = _nameColumn + 32; // AH
  static const int _leaveColumn = _absentColumn + 1; // AI
  static const int _presentColumn = _leaveColumn + 1; // AJ
  static const int _lateColumn = _presentColumn + 1; // AK
  static const int _rateColumn = _lateColumn + 1; // AL

  /// صف العنوان المدمج (1)، صف فارغ (2)، صف الترويسة (3)، ثم البيانات من 4.
  static const int _titleRow = 0;
  static const int _headerRow = 2;
  static const int _firstDataRow = 3;

  /// تجميد: عمودا «م» والاسم + صفوف العنوان والترويسة.
  static const int _freezeColumns = 2;
  static const int _freezeRows = 3;
  static const String _topLeftCell = 'C4';

  /// خلية واحدة بخط مقروء بدل `sheet.cell(CellIndex.indexByColumnRow(...))`
  /// المتشعّب على خمسة أسطر (وهو ما كان يشترط فاصلة زائدة).
  static Data _cellAt(Sheet sheet, int column, int row) {
    final Data c = sheet.cell(
      CellIndex.indexByColumnRow(columnIndex: column, rowIndex: row),
    );
    return c;
  }

  final Set<String> _usedSheetNames = <String>{};

  /// خط الكشف كله: أميري (موحّد مع التطبيق وتقرير PDF) حتى لا تظهر
  /// العربية بخط النظام الافتراضي المختلف.
  static const String _fontFamily = 'Amiri';

  /// نمط ترويسة موحّد (خلفية خضراء داكنة، نص أبيض عريض، توسيط).
  static CellStyle _headerStyle() => CellStyle(
        backgroundColorHex: ExcelColor.fromHexString(ExcelColors.header),
        fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
        fontFamily: _fontFamily,
        fontSize: 12,
        bold: true,
        horizontalAlign: HorizontalAlign.Center,
      );

  /// تقريب النسبة لمنزلة عشرية واحدة: القيمة الخام (66.666…) تظهر في
  /// الخلية بسلسلة كسور مزعجة بدل 66.7.
  static double _round1(double v) => (v * 10).roundToDouble() / 10;

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
    // ملاحظة: **لا** تُحذف ورقة القالب «Sheet1» هنا. `Excel.delete` ترفض حذف
    // الورقة الوحيدة (`if (_sheetMap.length <= 1) return;`) فتخرج بلا أثر،
    // ويبقى في ملف المستخدم تبويب «Sheet1» فارغ بجانب الكشوف العربية.
    // تُحذف في [_dropTemplateSheet] بعد إنشاء كل الأوراق.
    if (includeDaily) {
      for (final MonthKey m in months) {
        for (final ExportScopeClass sc in classes) {
          final Sheet sheet = excel[
              _sheetName('${sc.cls.grade}-${sc.cls.section}-${m.label}')];
          sheet.isRTL = true;
          _writeHeader(sheet, sc, m);
          int row = _firstDataRow;
          for (final Student s in sc.students) {
            final Map<String, int> byDate = <String, int>{
              for (final AttendanceRow r in await (db.select(db.attendanceRows)
                    ..where(
                      (a) => a.studentId.equals(s.id) & a.yearId.equals(year.id),
                    ))
                  .get())
                r.date: r.status,
            };
            final Data seq = sheet.cell(
              CellIndex.indexByColumnRow(columnIndex: _indexColumn, rowIndex: row),
            );
            seq.value = IntCellValue(row - _firstDataRow + 1);
            seq.cellStyle = CellStyle(
              fontFamily: _fontFamily,
              fontSize: 11,
              horizontalAlign: HorizontalAlign.Center,
            );
            final Data name = sheet.cell(
              CellIndex.indexByColumnRow(columnIndex: _nameColumn, rowIndex: row),
            );
            name.value = TextCellValue(s.fullName);
            // محاذاة صريحة من اليمين: لا نترك اتجاه الاسم لافتراض Excel.
            name.cellStyle = CellStyle(
              fontFamily: _fontFamily,
              fontSize: 11,
              horizontalAlign: HorizontalAlign.Right,
            );
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
                CellIndex.indexByColumnRow(
                  columnIndex: _dayColumn(day),
                  rowIndex: row,
                ),
              );
              cell.value = TextCellValue(
                status == null ? (schoolDay ? '' : 'عطلة') : _statusAr[status],
              );
              cell.cellStyle = CellStyle(
                backgroundColorHex:
                    ExcelColor.fromHexString(_colorFor(status, schoolDay)),
                fontFamily: _fontFamily,
                fontSize: 11,
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
            _cellAt(sheet, _absentColumn, row).value = IntCellValue(absent);
            _cellAt(sheet, _leaveColumn, row).value = IntCellValue(leave);
            _cellAt(sheet, _presentColumn, row).value = IntCellValue(present);
            _cellAt(sheet, _lateColumn, row).value = IntCellValue(late);
            final double rate =
                recorded == 0 ? 100 : (present + late) * 100 / recorded;
            _cellAt(sheet, _rateColumn, row).value =
                DoubleCellValue(_round1(rate));
            for (final int col in <int>[
              _absentColumn,
              _leaveColumn,
              _presentColumn,
              _lateColumn,
              _rateColumn,
            ]) {
              _cellAt(sheet, col, row).cellStyle = CellStyle(
                fontFamily: _fontFamily,
                fontSize: 11,
                horizontalAlign: HorizontalAlign.Center,
              );
            }
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
    _dropTemplateSheet(excel);
    final List<int>? bytes = excel.save();
    if (bytes == null) {
      throw StateError('excel save returned null');
    }
    return Uint8List.fromList(_patchSheets(bytes));
  }

  /// سجل طالب كامل بورقة واحدة: يوم لكل صف من بداية السنة حتى اليوم
  /// (مكبوتاً بنهاية السنة) + كتلة الإحصائيات الكلية (غياب/إجازات/تأخر).
  Future<Uint8List> buildStudentRecord({
    required Student student,
    required String classTitle,
    DateTime? today,
  }) async {
    final Excel excel = Excel.createExcel();
    final Sheet sheet = excel[_sheetName('سجل الطالب')];
    sheet.isRTL = true;
    final StudentRecord record = await reports.studentRecord(
      studentId: student.id,
      year: year,
      workWeekdays: workWeekdays,
      holidayKeys: holidayKeys,
      today: today,
    );
    _writeTitle(
      sheet,
      '$schoolName — سجل الطالب ${student.fullName} — $classTitle — '
      'السنة ${year.name} — حتى ${record.to} — المدير: $directorName',
      3,
    );
    const List<String> head = <String>['م', 'التاريخ', 'اليوم', 'الحالة'];
    _writeColumnHeaders(sheet, head);
    int row = _firstDataRow;
    int index = 1;
    for (final RecordDay d in record.days) {
      final DateTime dt = SchoolTime.parseKey(d.dateKey);
      _num(sheet, column: 0, row: row, value: IntCellValue(index++));
      _text(sheet, column: 1, row: row, value: d.dateKey);
      _text(
        sheet,
        column: 2,
        row: row,
        value: SchoolTime.weekdayNames[dt.weekday - 1],
      );
      final Data cell = _cellAt(sheet, 3, row);
      cell.value = TextCellValue(
        d.status == null
            ? (d.schoolDay ? 'لم يسجل' : 'عطلة')
            : _statusAr[d.status],
      );
      cell.cellStyle = CellStyle(
        backgroundColorHex:
            ExcelColor.fromHexString(_colorFor(d.status, d.schoolDay)),
        fontFamily: _fontFamily,
        fontSize: 11,
        horizontalAlign: HorizontalAlign.Right,
      );
      row++;
    }
    row++;
    final StatusTotals t = record.totals;
    final List<(String, CellValue)> stats = <(String, CellValue)>[
      ('إجمالي الحضور', IntCellValue(t.present)),
      ('إجمالي الغياب', IntCellValue(t.absent)),
      ('إجمالي الإجازات', IntCellValue(t.leave)),
      ('إجمالي التأخير', IntCellValue(t.late)),
      ('أيام مسجلة', IntCellValue(t.recorded)),
      ('نسبة الحضور %', DoubleCellValue(_round1(t.ratePct))),
    ];
    for (final (String, CellValue) st in stats) {
      _text(sheet, column: 1, row: row, value: st.$1);
      _num(sheet, column: 2, row: row, value: st.$2);
      row++;
    }
    sheet.setColumnWidth(0, 6.0);
    sheet.setColumnWidth(1, 16.0);
    sheet.setColumnWidth(2, 14.0);
    sheet.setColumnWidth(3, 14.0);
    _dropTemplateSheet(excel);
    final List<int>? bytes = excel.save();
    if (bytes == null) {
      throw StateError('excel save returned null');
    }
    return Uint8List.fromList(_patchSheets(bytes));
  }

  /// يحذف ورقة القالب «Sheet1» بعد أن صار في الملف أوراق حقيقية.
  ///
  /// تُستخدم `sheets` (لا `tables`) لأن `tables` ترمي «Corrupted Excel file»
  /// إن كانت الخريطة فارغة. وإن لم تُنشأ أي ورقة (تصدير بلا صفوف ولا ملخص)
  /// نُبقي «Sheet1» لأن ملف xlsx لا يصح بلا ورقة واحدة على الأقل.
  static void _dropTemplateSheet(Excel excel) {
    const String templateSheet = 'Sheet1';
    final Map<String, Sheet> sheets = excel.sheets;
    if (sheets.length > 1 && sheets.containsKey(templateSheet)) {
      excel.delete(templateSheet);
    }
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
    _writeTitle(
      sheet,
      '$schoolName — ملخص الحضور والغياب للسنة ${year.name} '
      '— المدير: $directorName',
      head.length - 1,
    );
    _writeColumnHeaders(sheet, head);
    int row = _firstDataRow;
    int index = 1;
    for (final ExportScopeClass sc in classes) {
      for (final Student s in sc.students) {
        final StatusTotals t = await reports.totalsForStudent(s.id, year.id);
        _num(
          sheet,
          column: 0,
          row: row,
          value: IntCellValue(index++),
        );
        _text(
          sheet,
          column: 1,
          row: row,
          value: '${sc.cls.grade} ـ ${sc.cls.section}',
        );
        _text(sheet, column: 2, row: row, value: s.fullName);
        _num(sheet, column: 3, row: row, value: IntCellValue(t.present));
        _num(sheet, column: 4, row: row, value: IntCellValue(t.late));
        _num(sheet, column: 5, row: row, value: IntCellValue(t.absent));
        _num(sheet, column: 6, row: row, value: IntCellValue(t.leave));
        _num(
          sheet,
          column: 7,
          row: row,
          value: DoubleCellValue(_round1(t.ratePct)),
        );
        row++;
      }
    }
    sheet.setColumnWidth(0, 6.0);
    sheet.setColumnWidth(1, 18.0);
    sheet.setColumnWidth(2, 34.0);
    for (int column = 3; column <= 6; column++) {
      sheet.setColumnWidth(column, 10.0);
    }
    sheet.setColumnWidth(7, 14.0);
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
    _writeTitle(
      sheet,
      '$schoolName — سجل الإجازات للسنة ${year.name} — المدير: $directorName',
      head.length - 1,
    );
    _writeColumnHeaders(sheet, head);
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
    int row = _firstDataRow;
    for (final Leave l in leaves) {
      _text(sheet, column: 0, row: row, value: names[l.studentId] ?? '-');
      _text(sheet, column: 1, row: row, value: l.start);
      _text(sheet, column: 2, row: row, value: l.end);
      _text(
        sheet,
        column: 3,
        row: row,
        value: l.type >= 0 && l.type < types.length
            ? types[l.type]
            : '${l.type}',
      );
      _text(sheet, column: 4, row: row, value: l.reason);
      row++;
    }
    sheet.setColumnWidth(0, 30.0);
    sheet.setColumnWidth(1, 14.0);
    sheet.setColumnWidth(2, 14.0);
    sheet.setColumnWidth(3, 12.0);
    sheet.setColumnWidth(4, 30.0);
  }

  /// عنوان مدمج في الصف الأول لكل ورقة.
  ///
  /// توحيد البنية (عنوان 1 + فراغ 2 + ترويسة 3 + بيانات 4+) يجعل تجميد
  /// الصفوف الثلاثة الأولى صحيحاً في **كل** أوراق الملف لا في الجداول الشهرية
  /// وحدها.
  void _writeTitle(Sheet sheet, String text, int lastColumn) {
    sheet.merge(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: _titleRow),
      CellIndex.indexByColumnRow(columnIndex: lastColumn, rowIndex: _titleRow),
    );
    final Data title = sheet.cell(
      CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: _titleRow),
    );
    title.value = TextCellValue(text);
    title.cellStyle = _headerStyle();
  }

  void _writeColumnHeaders(Sheet sheet, List<String> head) {
    for (int i = 0; i < head.length; i++) {
      final Data c = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: i, rowIndex: _headerRow),
      );
      c.value = TextCellValue(head[i]);
      c.cellStyle = _headerStyle();
    }
  }

  /// خلية نص بمحاذاة يمينية صريحة (اتجاه عربي لا يعتمد على افتراض Excel).
  void _text(
    Sheet sheet, {
    required int column,
    required int row,
    required String value,
  }) {
    final Data c = sheet.cell(
      CellIndex.indexByColumnRow(columnIndex: column, rowIndex: row),
    );
    c.value = TextCellValue(value);
    c.cellStyle = CellStyle(
      fontFamily: _fontFamily,
      fontSize: 11,
      horizontalAlign: HorizontalAlign.Right,
    );
  }

  /// خلية رقمية موسّطة.
  void _num(
    Sheet sheet, {
    required int column,
    required int row,
    required CellValue value,
  }) {
    final Data c = _cellAt(sheet, column, row);
    c.value = value;
    c.cellStyle = CellStyle(
      fontFamily: _fontFamily,
      fontSize: 11,
      horizontalAlign: HorizontalAlign.Center,
    );
  }

  void _writeHeader(Sheet sheet, ExportScopeClass sc, MonthKey m) {
    _writeTitle(
      sheet,
      '$schoolName — كشف حضور ${sc.cls.grade} ـ ${sc.cls.section} '
      '— ${m.label} — المدير: $directorName',
      _rateColumn,
    );
    _cellAt(sheet, _indexColumn, _headerRow).value = TextCellValue('م');
    _cellAt(sheet, _nameColumn, _headerRow).value =
        TextCellValue('اسم الطالب');
    for (int day = 1; day <= 31; day++) {
      final Data c = _cellAt(sheet, _dayColumn(day), _headerRow);
      c.value = TextCellValue(m.isValidDay(day) ? '$day' : '');
      c.cellStyle = _headerStyle();
    }
    final List<(int, String)> tails = <(int, String)>[
      (_absentColumn, 'غياب'),
      (_leaveColumn, 'إجازة'),
      (_presentColumn, 'حضور'),
      (_lateColumn, 'متأخر'),
      (_rateColumn, 'نسبة الحضور'),
    ];
    for (final (int col, String label) in tails) {
      _cellAt(sheet, col, _headerRow).value = TextCellValue(label);
    }
    for (final int col in <int>[
      _indexColumn,
      _nameColumn,
      _absentColumn,
      _leaveColumn,
      _presentColumn,
      _lateColumn,
      _rateColumn,
    ]) {
      _cellAt(sheet, col, _headerRow).cellStyle = _headerStyle();
    }
    sheet.setColumnWidth(_indexColumn, 6.0);
    sheet.setColumnWidth(_nameColumn, 34.0);
    // أعمدة الأيام والمجاميع بعرض صريح: بدونه تُقصّ كلمات «متأخر/إجازة»
    // في العرض الافتراضي الضيق.
    for (int day = 1; day <= 31; day++) {
      sheet.setColumnWidth(_dayColumn(day), 11.0);
    }
    for (final int col in <int>[
      _absentColumn,
      _leaveColumn,
      _presentColumn,
      _lateColumn,
    ]) {
      sheet.setColumnWidth(col, 10.0);
    }
    sheet.setColumnWidth(_rateColumn, 14.0);
  }

  /// ترقيع أوراق الـxlsx بعد الحفظ: **فرض الاتجاه من اليمين إلى اليسار**
  /// (`rightToLeft="1"`) + تجميد أول عمودين وصفوف العنوان.
  ///
  /// لماذا يدوياً؟ اتجاه الورقة في Excel سمة `sheetView`، وأي خلل فيها يفتح
  /// الملف باتجاه إنكليزي (LTR) فينعكس ترتيب الأعمدة ويظهر الاسم في الجهة
  /// الخطأ. نفرضها هنا صراحةً ولا نتكل على ما تكتبه نسخة الحزمة.
  ///
  /// الفكّ والتركيب بـUTF-8 (لا `String.fromCharCodes`/`codeUnits`) حتى لا
  /// تفسد أي نصوص عربية داخل الأوراق.
  List<int> _patchSheets(List<int> bytes) {
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final Archive out = Archive();
    for (final ArchiveFile f in archive) {
      if (f.name == 'xl/styles.xml') {
        final String xml =
            utf8.decode(f.content as List<int>, allowMalformed: true);
        final List<int> patched = utf8.encode(_patchStylesRtl(xml));
        out.addFile(ArchiveFile(f.name, patched.length, patched));
        continue;
      }
      if (!_isWorksheetXml(f.name)) {
        out.addFile(f);
        continue;
      }
      final String xml =
          utf8.decode(f.content as List<int>, allowMalformed: true);
      final List<int> patched = utf8.encode(_patchSheetView(xml));
      out.addFile(ArchiveFile(f.name, patched.length, patched));
    }
    return ZipEncoder().encode(out)!;
  }

  /// يضيف `readingOrder="2"` (اتجاه قراءة RTL) لكل `alignment` محاذاته
  /// `right` في `styles.xml` — الحزمة لا تدعم اتجاه القراءة، والمحاذاة
  /// وحدها لا تضبط اتجاه الأسماء بدقة في كل العارضات.
  ///
  /// آمن لأن كل الخلايا يمينية المحاذاة في ملفاتنا نص عربي أو محايد
  /// (أسماء، صفوف، تواريخ، أسباب إجازات) — لا أرقام تُحسَب ولا عناوين
  /// موسّطة تشاركها النمط نفسه. الوسوم الحاملة `readingOrder` مسبقاً
  /// تُترَك كما هي (لا تكرار للسمة).
  String _patchStylesRtl(String xml) {
    return xml.replaceAllMapped(
      RegExp(r'<alignment\b[^>]*>'),
      (Match m) {
        final String tag = m.group(0)!;
        if (!tag.contains('horizontal="right"') ||
            tag.contains('readingOrder=')) {
          return tag;
        }
        if (tag.endsWith('/>')) {
          return '${tag.substring(0, tag.length - 2)} readingOrder="2"/>';
        }
        return '${tag.substring(0, tag.length - 1)} readingOrder="2">';
      },
    );
  }

  static bool _isWorksheetXml(String name) =>
      name.startsWith('xl/worksheets/sheet') && name.endsWith('.xml');

  /// يعيد بناء `sheetViews` بناءً قانونياً: **كتلة واحدة** في الموضع الذي
  /// يشترطه مخطط OOXML (بعد `sheetPr` و`dimension` وقبل `sheetFormatPr`
  /// و`sheetData`)، وتحمل `rightToLeft="1"` و`pane` التجميد.
  ///
  /// لماذا الحذف وإعادة الإدخال بدل ترقيع الموجود؟ لأن حزمة `excel` تُدرج
  /// `sheetViews` — حين لا تجدها في قالب الورقة — في **آخر** وسم `worksheet`،
  /// وهو موضع مخالف لترتيب المخطط: إكسل يتجاهله أو يفتح الملف برسالة «وجدنا
  /// مشكلة في بعض المحتوى». والنتيجة في الميدان هي شكوى المستخدم حرفياً:
  /// كشفٌ عربي يُفتح باتجاه إنكليزي والاسم في الجهة الخطأ.
  static String _patchSheetView(String xml) {
    const String pane = '<pane xSplit="$_freezeColumns" ySplit="$_freezeRows" '
        'topLeftCell="$_topLeftCell" activePane="bottomRight" state="frozen"/>';
    // كتلة الحاوية: وسم مغلق ذاتياً أو مفتوح مع إغلاقه (غير شرهي).
    final RegExp blocks = RegExp(
      r'<sheetViews(?:\s[^>]*)?/>'
      r'|<sheetViews(?:\s[^>]*)?>[\s\S]*?</sheetViews>',
    );
    // `\s` بعد اسم الوسم ضروري: بدونه يلتقط `<sheetViews>` (الحاوية) بالخطأ.
    final RegExp viewTag = RegExp(r'<sheetView(?:\s[^>]*)?/?>');
    final RegExpMatch? block = blocks.firstMatch(xml);
    final RegExpMatch? view =
        block == null ? null : viewTag.firstMatch(block.group(0)!);
    // نحذف كل الكتل (قد تكون الحزمة كرّرتها) ثم نعيد كتلة واحدة نظيفة.
    final String stripped = xml.replaceAll(blocks, '');
    final String attrs = _withRtl(view == null ? '' : _attrsOf(view.group(0)!));
    final String views =
        '<sheetViews><sheetView $attrs>$pane</sheetView></sheetViews>';
    for (final RegExp anchor in <RegExp>[
      RegExp(r'<dimension[^>]*/>'),
      RegExp(r'<dimension[^>]*>[\s\S]*?</dimension>'),
      RegExp(r'<sheetPr[^>]*/>'),
      RegExp(r'<sheetPr[^>]*>[\s\S]*?</sheetPr>'),
      RegExp(r'<worksheet[^>]*>'),
    ]) {
      final RegExpMatch? m = anchor.firstMatch(stripped);
      if (m != null) {
        return stripped.replaceRange(m.end, m.end, views);
      }
    }
    return stripped;
  }

  /// سمات وسم `sheetView` بلا اسم الوسم وبلا `/` الإغلاق الذاتي.
  static String _attrsOf(String tag) {
    String a = tag.substring('<sheetView'.length);
    if (a.endsWith('/>')) {
      a = a.substring(0, a.length - 2);
    } else if (a.endsWith('>')) {
      a = a.substring(0, a.length - 1);
    }
    return a.trim();
  }

  /// يفرض `rightToLeft="1"` في سمات وسم `sheetView`: يضيفها إن غابت ويصحّح
  /// قيمتها إن كُتبت بخلاف `1`، ويضمن `workbookViewId` (سمة إلزامية في
  /// المخطط).
  static String _withRtl(String attrs) {
    String a = attrs.trim();
    a = a.contains('rightToLeft')
        ? a.replaceAll(
            RegExp(r'rightToLeft\s*=\s*"[^"]*"'),
            'rightToLeft="1"',
          )
        : '$a rightToLeft="1"';
    if (!a.contains('workbookViewId')) {
      a = '$a workbookViewId="0"';
    }
    return a.trim();
  }

  // ---------------- اسم الملف المصدَّر ----------------

  /// اسم ملف عربي واضح للمشاركة بدل `hodor-<طابع زمني>.xlsx` اللاتيني.
  ///
  /// مثال: `كشف الحضور والغياب - مدرسة النجاح - 2026-2027 - آذار 2026.xlsx`
  static String exportFileName({
    required String schoolName,
    required String yearName,
    required List<MonthKey> months,
    DateTime? now,
  }) {
    final DateTime stamp = now ?? DateTime.now();
    final String scope = switch (months.length) {
      0 => 'ملخص',
      1 => months.first.label,
      _ => '${months.first.label} إلى ${months.last.label}',
    };
    // التاريخ والوقت يمنعان تصديرين من المشاركة في الاسم نفسه داخل المجلد
    // المؤقت (ملف قيد الإرسال لا يُستبدل بآخر).
    final String when = '${SchoolTime.dateKey(stamp)} '
        '${stamp.hour.toString().padLeft(2, '0')}'
        '-${stamp.minute.toString().padLeft(2, '0')}';
    final String base = <String>[
      'كشف الحضور والغياب',
      if (schoolName.trim().isNotEmpty) schoolName.trim(),
      if (yearName.trim().isNotEmpty) yearName.trim(),
      scope,
      when,
    ].join(' - ');
    return '${sanitizeFileName(base)}.xlsx';
  }

  /// اسم ملف سجل الطالب: «سجل الطالب - الاسم - السنة - التاريخ.xlsx».
  static String recordFileName({
    required String studentName,
    required String yearName,
    DateTime? now,
  }) {
    final DateTime stamp = now ?? DateTime.now();
    final String base = <String>[
      'سجل الطالب',
      if (studentName.trim().isNotEmpty) studentName.trim(),
      if (yearName.trim().isNotEmpty) yearName.trim(),
      SchoolTime.dateKey(stamp),
    ].join(' - ');
    return '${sanitizeFileName(base)}.xlsx';
  }

  /// اسم ملف صالح: يحذف المحارف الممنوعة في أنظمة الملفات ويحدّ الطول.
  static String sanitizeFileName(String raw) {
    String n = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (n.isEmpty) {
      n = 'تقرير الحضور';
    }
    if (n.length > 90) {
      n = n.substring(0, 90).trim();
    }
    return n;
  }
}
