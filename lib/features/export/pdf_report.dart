/// تقرير PDF شهري ملوّن واحترافي مطابق لمنطق الإكسل، بعربية مشكّلة صحيحة.
/// باتجاه RTL سليم: تسلسل واسم الطالب في اليمين، أيام الشهر، والمجاميع في اليسار.
library;

import 'package:drift/drift.dart' hide Column;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/arabic_shaping.dart';
import '../../core/attendance_labels.dart';
import '../../core/lesson.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/reports_service.dart';
import 'excel_builder.dart';

class PdfReport {
  PdfReport({
    required this.db,
    required this.reports,
    required this.schoolName,
    required this.directorName,
    required this.year,
    required this.months,
    required this.classes,
    required this.workWeekdays,
    required this.holidayKeys,
    required this.font,
    required this.fontBold,
    this.includeDaily = true,
    this.includeSummary = true,
    this.includeAbsences = false,
    this.includeLessonLog = true,
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
  final pw.Font font;
  final pw.Font fontBold;
  final bool includeDaily;
  final bool includeSummary;

  /// قسم «الغيابات فقط»: غيابات كل طالب وحدها — مرآة ورقة إكسل نفسها.
  final bool includeAbsences;

  /// صفحة «سجل الحصص»: كل حصة سطر مستقل — التفصيل الذي لا يتسع له جدول
  /// الشهر (خلية اليوم تعرض حروف الحصص فقط).
  final bool includeLessonLog;

  static const double _dayW = 17.5;

  pw.TextStyle _s(double size, {bool bold = false, PdfColor? color}) =>
      pw.TextStyle(font: bold ? fontBold : font, fontSize: size, color: color);

  /// نص بصري جاهز للرسم باتجاه LTR دائماً (انظر تحذير arabic_shaping:
  /// ممنوع لفّ المخرجات بـ`Directionality(rtl)`).
  static String _t(String s) => arabicForPdf(s);

  /// يلحم أجزاء العنوان بشرطة طويلة متجاهلاً الفارغ منها، حتى لا تظهر
  /// « — » يتيمة عندما يكون اسم المدرسة أو المدير غير مضبوط.
  static String _join(List<String> parts) => parts
      .map((String p) => p.trim())
      .where((String p) => p.isNotEmpty)
      .join(' — ');

  PdfColor _colorFor(int? status, bool schoolDay, {bool partial = false}) {
    if (!schoolDay) {
      return PdfColor.fromInt(StatusHex.asInt(StatusHex.offDay));
    }
    if (partial) {
      return PdfColor.fromInt(StatusHex.asInt(StatusHex.absentPartial));
    }
    switch (status) {
      case AttendanceStatus.present:
        return const PdfColor.fromInt(0xFFC6EFCE);
      case AttendanceStatus.absent:
        return const PdfColor.fromInt(0xFFFFC7CE);
      case AttendanceStatus.leave:
        return const PdfColor.fromInt(0xFFFFEB9C);
      case AttendanceStatus.late:
        return const PdfColor.fromInt(0xFFFCD5B4);
      default:
        return PdfColors.white;
    }
  }

  /// حروف حالات حصص اليوم بترتيب الجدول («غ·—·ح»).
  ///
  /// الترتيب يُعكس بصرياً في [arabicForPdf] فيظهر رقم الحصة الأولى على
  /// اليمين — اتجاه القراءة العربي نفسه المتبع في بقية التقرير.
  String _dayMarks(List<Lesson> lessons, Map<int, int> statuses, bool schoolDay) {
    if (!schoolDay) {
      return _t('ع');
    }
    if (statuses.isEmpty) {
      return '';
    }
    // المصدر نفسه الذي تستخدمه الشاشة وملف Excel — لا نسخة ثالثة للحروف.
    return _t(lessonCompactMarks(_windows(lessons), statuses));
  }

  /// تحويل صفوف الحصص إلى نوافذ عرض (المصدر الموحّد للتسمية والحروف).
  static List<LessonWindow> _windows(List<Lesson> lessons) =>
      <LessonWindow>[for (final Lesson l in lessons) AppDb.windowOf(l)];

  PdfColor _letterColor(int? status, bool schoolDay) {
    if (!schoolDay) {
      return const PdfColor.fromInt(0xFF757575);
    }
    switch (status) {
      case AttendanceStatus.present:
        return const PdfColor.fromInt(0xFF1E7E34);
      case AttendanceStatus.absent:
        return const PdfColor.fromInt(0xFFB71C1C);
      case AttendanceStatus.leave:
        return const PdfColor.fromInt(0xFF8A6D3B);
      case AttendanceStatus.late:
        return const PdfColor.fromInt(0xFFD35400);
      default:
        return PdfColors.black;
    }
  }

  Map<int, pw.TableColumnWidth> _dailyWidths() => <int, pw.TableColumnWidth>{
        0: const pw.FixedColumnWidth(28),
        1: const pw.FixedColumnWidth(22),
        2: const pw.FixedColumnWidth(22),
        3: const pw.FixedColumnWidth(22),
        4: const pw.FixedColumnWidth(22),
        for (int i = 5; i <= 35; i++) i: const pw.FixedColumnWidth(_dayW),
        36: const pw.FlexColumnWidth(1),
        37: const pw.FixedColumnWidth(18),
      };

  pw.TableRow _headerRow(MonthKey m) {
    final List<pw.Widget> cells = <pw.Widget>[
      _th(_t('النسبة')),
      _th(_t('إجازة')),
      _th(_t('غياب')),
      _th(_t('متأخر')),
      _th(_t('حاضر')),
    ];
    for (int day = 31; day >= 1; day--) {
      cells.add(
        pw.Container(
          height: 15,
          color: m.isValidDay(day)
              ? PdfColors.teal800
              : const PdfColor.fromInt(0xFF004D40),
          alignment: pw.Alignment.center,
          child: pw.Text(
            m.isValidDay(day) ? '$day' : '',
            style: _s(6, bold: true, color: PdfColors.white),
          ),
        ),
      );
    }
    cells.add(_th(_t('اسم الطالب'), align: pw.Alignment.centerRight, padH: 4));
    cells.add(_th(_t('ت')));
    return pw.TableRow(children: cells);
  }

  pw.Widget _th(
    String text, {
    pw.Alignment align = pw.Alignment.center,
    double padH = 1,
  }) =>
      pw.Container(
        height: 15,
        color: PdfColors.teal800,
        alignment: align,
        padding: pw.EdgeInsets.symmetric(horizontal: padH),
        child: pw.Text(
          text,
          style: _s(6.5, bold: true, color: PdfColors.white),
          textAlign: pw.TextAlign.center,
        ),
      );

  pw.Widget _legendItem(String label, PdfColor color) => pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: <pw.Widget>[
          pw.Text(_t(label), style: _s(6.5, bold: true)),
          pw.SizedBox(width: 3),
          pw.Container(
            width: 8,
            height: 8,
            decoration: pw.BoxDecoration(
              color: color,
              border: pw.Border.all(color: PdfColors.grey600, width: 0.5),
            ),
          ),
        ],
      );

  Future<pw.Document> build() async {
    final pw.Document doc = pw.Document(
      title: 'تقارير الحضور والغياب',
      theme: pw.ThemeData.withFont(base: font, bold: fontBold),
    );
    final List<Lesson> lessons = await db.allLessons();
    if (includeDaily) {
      for (final MonthKey m in months) {
        for (final ExportScopeClass sc in classes) {
          final List<pw.TableRow> rows = <pw.TableRow>[_headerRow(m)];
          for (int studentIdx = 0; studentIdx < sc.students.length; studentIdx++) {
            final Student s = sc.students[studentIdx];
            // فلترة الشهر في SQL: جدول الشهر لا يحتاج سجلات السنة كلها.
            final String monthFrom = SchoolTime.dateKey(m.first);
            final String monthTo = SchoolTime.dateKey(m.last);
            final Map<String, List<AttendanceRow>> byDate =
                <String, List<AttendanceRow>>{};
            for (final AttendanceRow r in await (db.select(db.attendanceRows)
                  ..where(
                    (a) =>
                        a.studentId.equals(s.id) &
                        a.yearId.equals(year.id) &
                        a.date.isBiggerOrEqualValue(monthFrom) &
                        a.date.isSmallerOrEqualValue(monthTo),
                  ))
                .get()) {
              byDate.putIfAbsent(r.date, () => <AttendanceRow>[]).add(r);
            }
            int absent = 0;
            int leave = 0;
            int present = 0;
            int late = 0;

            final Map<int, (int?, bool, Map<int, int>)> dayStatuses =
                <int, (int?, bool, Map<int, int>)>{};
            for (int day = 1; day <= 31; day++) {
              if (!m.isValidDay(day)) {
                continue;
              }
              final DateTime d = DateTime(m.year, m.month, day);
              final List<AttendanceRow> dayRows =
                  byDate[SchoolTime.dateKey(d)] ?? const <AttendanceRow>[];
              final Map<int, int> statuses = <int, int>{
                for (final AttendanceRow r in dayRows) r.lessonId: r.status,
              };
              final int? status =
                  ReportsService.aggregateStatus(statuses.values);
              final bool schoolDay = SchoolTime.isSchoolDay(
                d,
                workWeekdays: workWeekdays,
                holidayKeys: holidayKeys,
              );
              dayStatuses[day] = (status, schoolDay, statuses);
              // العدّ بالحصص (كل سطر حصة) لا بالأيام.
              for (final AttendanceRow r in dayRows) {
                switch (r.status) {
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
            }

            final int recorded = present + absent + leave + late;
            final String rateStr = recorded == 0
                ? '100%'
                : '${((present + late) * 100 / recorded).toStringAsFixed(0)}%';

            final List<pw.Widget> cells = <pw.Widget>[
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text(rateStr, style: _s(6, bold: true)),
              ),
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text('$leave', style: _s(6)),
              ),
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text(
                  '$absent',
                  style: _s(
                    6,
                    bold: absent > 0,
                    color: absent > 0 ? PdfColors.red900 : PdfColors.black,
                  ),
                ),
              ),
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text('$late', style: _s(6)),
              ),
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text('$present', style: _s(6)),
              ),
            ];

            for (int day = 31; day >= 1; day--) {
              if (!m.isValidDay(day)) {
                cells.add(
                  pw.Container(
                    height: 13,
                    color: const PdfColor.fromInt(0xFFE8E8E8),
                  ),
                );
                continue;
              }
              final (int?, bool, Map<int, int>) info = dayStatuses[day] ??
                  (null, true, const <int, int>{});
              final int? status = info.$1;
              final bool schoolDay = info.$2;
              final Map<int, int> statuses = info.$3;
              final bool partialAbsence = describeDay(
                status: status,
                lessonStatuses: statuses,
                totalLessons: lessons.length,
              ).isPartial;
              cells.add(
                pw.Container(
                  height: 13,
                  color: _colorFor(status, schoolDay, partial: partialAbsence),
                  alignment: pw.Alignment.center,
                  child: pw.Text(
                    _dayMarks(lessons, statuses, schoolDay),
                    style: _s(
                      4.2,
                      bold: true,
                      color: _letterColor(status, schoolDay),
                    ),
                  ),
                ),
              );
            }

            cells.add(
              pw.Container(
                height: 13,
                alignment: pw.Alignment.centerRight,
                padding: const pw.EdgeInsets.symmetric(horizontal: 4),
                child: pw.Text(
                  _t(s.fullName),
                  style: _s(6.5, bold: true),
                  maxLines: 1,
                ),
              ),
            );
            cells.add(
              pw.Container(
                height: 13,
                alignment: pw.Alignment.center,
                child: pw.Text('${studentIdx + 1}', style: _s(6)),
              ),
            );

            rows.add(pw.TableRow(children: cells));
          }

          doc.addPage(
            pw.MultiPage(
              pageFormat: PdfPageFormat.a4.landscape,
              margin: const pw.EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              header: (pw.Context c) => pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: <pw.Widget>[
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: <pw.Widget>[
                      pw.Text(
                        _t('نظام حضور الطالب — كشف الحضور والغياب الشهري'),
                        style: _s(7.5, color: PdfColors.grey700),
                      ),
                      pw.Text(
                        _t(
                          _join(<String>[
                            schoolName,
                            '${sc.cls.grade} ـ ${sc.cls.section}',
                            m.label,
                          ]),
                        ),
                        style: _s(11, bold: true, color: PdfColors.teal900),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 3),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: <pw.Widget>[
                      pw.Row(
                        children: <pw.Widget>[
                          _legendItem('عطلة', const PdfColor.fromInt(0xFFD9D9D9)),
                          pw.SizedBox(width: 8),
                          _legendItem('متأخر', const PdfColor.fromInt(0xFFFCD5B4)),
                          pw.SizedBox(width: 8),
                          _legendItem('إجازة', const PdfColor.fromInt(0xFFFFEB9C)),
                          pw.SizedBox(width: 8),
                          _legendItem(
                            'غياب جزئي',
                            PdfColor.fromInt(StatusHex.asInt(StatusHex.absentPartial)),
                          ),
                          pw.SizedBox(width: 8),
                          _legendItem('غائب', const PdfColor.fromInt(0xFFFFC7CE)),
                          pw.SizedBox(width: 8),
                          _legendItem('حاضر', const PdfColor.fromInt(0xFFC6EFCE)),
                        ],
                      ),
                      pw.Text(
                        _t(
                          _join(<String>[
                            if (directorName.trim().isNotEmpty)
                              'المدير: $directorName',
                            'السنة: ${year.name}',
                          ]),
                        ),
                        style: _s(7.5, bold: true),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 4),
                ],
              ),
              build: (pw.Context c) => <pw.Widget>[
                if (sc.students.isEmpty)
                  pw.Center(
                    child: pw.Padding(
                      padding: const pw.EdgeInsets.all(32),
                      child: pw.Text(
                        _t('لا طلاب مسجلون في هذا الصف بعد'),
                        style: _s(10),
                      ),
                    ),
                  )
                else ...<pw.Widget>[
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 2),
                    child: pw.Text(
                      _t(
                        'خلايا اليوم = حروف الحصص بالترتيب — '
                        'ح: حاضر، غ: غائب، إ: إجازة، م: متأخر، —: لم تُسجَّل',
                      ),
                      style: _s(5.5, color: PdfColors.grey700),
                    ),
                  ),
                  pw.Table(
                    columnWidths: _dailyWidths(),
                    border: pw.TableBorder.all(
                      width: 0.5,
                      color: PdfColors.grey400,
                    ),
                    defaultVerticalAlignment:
                        pw.TableCellVerticalAlignment.middle,
                    children: rows,
                  ),
                ],
              ],
            ),
          );
        }
      }
    }
    if (includeSummary) {
      await _addSummary(doc, lessons);
    }
    if (includeLessonLog) {
      await _addLessonLog(doc, lessons);
    }
    if (includeAbsences) {
      await _addAbsences(doc, lessons);
    }
    return doc;
  }

  /// قسم الغيابات فقط: كل يوم غياب لكل طالب ضمن النطاق (الأشهر المحددة
  /// أو السنة كلها)، صفحة بورتريه لكل صف مع إجمالي غياباته في الأسفل —
  /// مطابق منطقياً لورقة «سجل الغيابات» في ملف الإكسل.
  Future<void> _addAbsences(
    pw.Document doc,
    List<Lesson> lessons,
  ) async {
    final Map<int, Lesson> lessonById = <int, Lesson>{
      for (final Lesson l in lessons) l.id: l,
    };
    final Set<String> monthKeys = <String>{
      for (final MonthKey m in months) m.key,
    };
    for (final ExportScopeClass sc in classes) {
      final List<pw.TableRow> rows = <pw.TableRow>[
        pw.TableRow(
          children: <pw.Widget>[
            _th(_t('طريقة التسجيل')),
            _th(_t('وقت الحصة'), padH: 2),
            _th(_t('الحصة'), padH: 2),
            _th(_t('اليوم')),
            _th(_t('تاريخ الغياب')),
            _th(_t('اسم الطالب'), align: pw.Alignment.centerRight, padH: 6),
            _th(_t('الصف')),
            _th(_t('م')),
          ],
        ),
      ];
      int index = 1;
      int total = 0;
      final Set<String> absentDays = <String>{};
      for (final Student s in sc.students) {
        final List<AttendanceRow> absences = await (db.select(db.attendanceRows)
              ..where(
                (a) =>
                    a.studentId.equals(s.id) &
                    a.yearId.equals(year.id) &
                    a.status.equals(AttendanceStatus.absent),
              )
              ..orderBy(<OrderClauseGenerator<AttendanceRows>>[
                (AttendanceRows a) => OrderingTerm.asc(a.date),
              ]))
            .get();
        for (final AttendanceRow r in absences) {
          // yyyy-MM-dd ⇒ مفتاح الشهر أول سبعة محارف.
          if (monthKeys.isNotEmpty &&
              !monthKeys.contains(r.date.substring(0, 7))) {
            continue;
          }
          final DateTime dt = SchoolTime.parseKey(r.date);
          final Lesson? lesson = lessonById[r.lessonId];
          rows.add(
            pw.TableRow(
              children: <pw.Widget>[
                _absCell(ExcelBuilder.sourceLabel(r.source)),
                _absCell(
                  lesson == null ? '' : '${lesson.start}–${lesson.end}',
                ),
                _absCell(
                  lesson == null ? '—' : AppDb.windowOf(lesson).displayName,
                ),
                _absCell(SchoolTime.weekdayNames[dt.weekday - 1]),
                // تاريخ الغياب بخلية حمراء مطابقة لنظام ألوان الحالات.
                pw.Container(
                  height: 16,
                  color: const PdfColor.fromInt(0xFFFFC7CE),
                  alignment: pw.Alignment.center,
                  child: pw.Text(
                    r.date,
                    style: _s(7, bold: true),
                    textAlign: pw.TextAlign.center,
                    maxLines: 1,
                  ),
                ),
                pw.Container(
                  height: 16,
                  alignment: pw.Alignment.centerRight,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 6),
                  child: pw.Text(
                    _t(s.fullName),
                    style: _s(7, bold: true),
                    maxLines: 1,
                  ),
                ),
                _absCell('${sc.cls.grade} ـ ${sc.cls.section}'),
                _absCell('$index'),
              ],
            ),
          );
          index++;
          total++;
          absentDays.add(r.date);
        }
      }
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          header: (pw.Context c) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: <pw.Widget>[
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  pw.Text(
                    _t('نظام حضور الطالب — سجل الغيابات'),
                    style: _s(8, color: PdfColors.grey700),
                  ),
                  pw.Text(
                    _t(
                      _join(<String>[
                        schoolName,
                        'سجل الغيابات',
                        '${sc.cls.grade} ـ ${sc.cls.section}',
                      ]),
                    ),
                    style: _s(11, bold: true, color: PdfColors.teal900),
                  ),
                ],
              ),
              pw.SizedBox(height: 3),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  pw.Text(
                    _t(
                      months.isEmpty
                          ? 'النطاق: السنة الدراسية ${year.name} كاملة'
                          : 'النطاق: ${months.first.label}'
                              '${months.length > 1 ? ' إلى ${months.last.label}' : ''}',
                    ),
                    style: _s(8),
                  ),
                  if (directorName.trim().isNotEmpty)
                    pw.Text(
                      _t('المدير: $directorName'),
                      style: _s(8, bold: true),
                    ),
                ],
              ),
              pw.SizedBox(height: 6),
            ],
          ),
          build: (pw.Context c) => <pw.Widget>[
            if (total == 0)
              pw.Center(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.all(32),
                  child: pw.Text(
                    _t('لا غيابات مسجلة لهذا الصف ضمن النطاق المحدد'),
                    style: _s(10),
                  ),
                ),
              )
            else ...<pw.Widget>[
              pw.Table(
                columnWidths: <int, pw.TableColumnWidth>{
                  0: const pw.FixedColumnWidth(62),
                  1: const pw.FixedColumnWidth(56),
                  2: const pw.FixedColumnWidth(64),
                  3: const pw.FixedColumnWidth(52),
                  4: const pw.FixedColumnWidth(66),
                  5: const pw.FlexColumnWidth(1),
                  6: const pw.FixedColumnWidth(78),
                  7: const pw.FixedColumnWidth(22),
                },
                border: pw.TableBorder.all(
                  width: 0.5,
                  color: PdfColors.grey400,
                ),
                defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
                children: rows,
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                _t(
                  'إجمالي حصص الغياب: $total — عدد الأيام: ${absentDays.length}',
                ),
                style: _s(9, bold: true, color: PdfColors.teal900),
              ),
            ],
          ],
        ),
      );
    }
  }

  /// خلية موسّطة في جدول الغيابات.
  pw.Widget _absCell(String text) => pw.Container(
        height: 16,
        alignment: pw.Alignment.center,
        child: pw.Text(
          _t(text),
          style: _s(7),
          textAlign: pw.TextAlign.center,
          maxLines: 1,
        ),
      );

  /// صفحة «سجل الحصص»: كل واقعة حضور/غياب سطر مستقل لكل طالب في كل حصة.
  ///
  /// لماذا صفحة مستقلة؟ جدول الشهر يعرض حروف الحصص في خلية اليوم (ضيّقة)،
  /// وهذا الجدول هو التفصيل الكامل القابل للطباعة والتسليم: الحالة، وقت
  /// الحصة، وقت الوصول، ومصدر التسجيل.
  Future<void> _addLessonLog(
    pw.Document doc,
    List<Lesson> lessons,
  ) async {
    final Map<int, Lesson> lessonById = <int, Lesson>{
      for (final Lesson l in lessons) l.id: l,
    };
    final Set<String> monthKeys = <String>{
      for (final MonthKey m in months) m.key,
    };
    for (final ExportScopeClass sc in classes) {
      final List<LessonLogRow> log = await reports.lessonLog(
        yearId: year.id,
        studentIds: <int>[for (final Student s in sc.students) s.id],
        monthKeys: monthKeys,
      );
      final List<LessonLogRow> sorted = log.toList()
        ..sort((LessonLogRow a, LessonLogRow b) {
          final int byStudent = a.student.fullName.compareTo(b.student.fullName);
          if (byStudent != 0) {
            return byStudent;
          }
          final int byDate = a.row.date.compareTo(b.row.date);
          return byDate != 0 ? byDate : a.lesson.slot.compareTo(b.lesson.slot);
        });
      final List<pw.TableRow> rows = <pw.TableRow>[
        pw.TableRow(
          children: <pw.Widget>[
            _th(_t('المصدر'), padH: 2),
            _th(_t('وقت الوصول'), padH: 2),
            _th(_t('الحالة'), padH: 2),
            _th(_t('وقت الحصة'), padH: 2),
            _th(_t('الحصة'), padH: 2),
            _th(_t('اليوم'), padH: 2),
            _th(_t('التاريخ'), padH: 2),
            _th(_t('اسم الطالب'), align: pw.Alignment.centerRight, padH: 6),
            _th(_t('م'), padH: 2),
          ],
        ),
      ];
      int index = 1;
      for (final LessonLogRow entry in sorted) {
        final AttendanceRow r = entry.row;
        final Lesson lesson = lessonById[r.lessonId] ?? entry.lesson;
        final DateTime dt = SchoolTime.parseKey(r.date);
        rows.add(
          pw.TableRow(
            children: <pw.Widget>[
              _absCell(ExcelBuilder.sourceLabel(r.source)),
              _absCell(r.arrivalTime ?? ''),
              pw.Container(
                height: 16,
                color: _colorFor(r.status, true),
                alignment: pw.Alignment.center,
                child: pw.Text(
                  _t(_statusText(r.status)),
                  style: _s(6.5, bold: r.status == AttendanceStatus.absent),
                ),
              ),
              _absCell('${lesson.start}–${lesson.end}'),
              _absCell(
                lesson.name.trim().isEmpty
                    ? 'ح${lesson.slot}'
                    : lesson.name,
              ),
              _absCell(SchoolTime.weekdayNames[dt.weekday - 1]),
              _absCell(r.date),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.centerRight,
                padding: const pw.EdgeInsets.symmetric(horizontal: 6),
                child: pw.Text(
                  _t(entry.student.fullName),
                  style: _s(6.5, bold: true),
                  maxLines: 1,
                ),
              ),
              _absCell('$index'),
            ],
          ),
        );
        index++;
      }
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          header: (pw.Context c) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: <pw.Widget>[
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  pw.Text(
                    _t('نظام حضور الطالب — سجل الحصص التفصيلي'),
                    style: _s(8, color: PdfColors.grey700),
                  ),
                  pw.Text(
                    _t(
                      _join(<String>[
                        schoolName,
                        'سجل الحصص',
                        '${sc.cls.grade} ـ ${sc.cls.section}',
                      ]),
                    ),
                    style: _s(11, bold: true, color: PdfColors.teal900),
                  ),
                ],
              ),
              pw.SizedBox(height: 3),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  pw.Text(
                    _t(
                      months.isEmpty
                          ? 'النطاق: السنة الدراسية ${year.name} كاملة'
                          : 'النطاق: ${months.first.label}'
                              '${months.length > 1 ? ' إلى ${months.last.label}' : ''}',
                    ),
                    style: _s(8),
                  ),
                  if (directorName.trim().isNotEmpty)
                    pw.Text(
                      _t('المدير: $directorName'),
                      style: _s(8, bold: true),
                    ),
                ],
              ),
              pw.SizedBox(height: 6),
            ],
          ),
          build: (pw.Context c) => <pw.Widget>[
            if (sorted.isEmpty)
              pw.Center(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.all(32),
                  child: pw.Text(
                    _t('لا تسجيلات في النطاق المحدد'),
                    style: _s(10),
                  ),
                ),
              )
            else ...<pw.Widget>[
              pw.Table(
                columnWidths: <int, pw.TableColumnWidth>{
                  0: const pw.FixedColumnWidth(58),
                  1: const pw.FixedColumnWidth(52),
                  2: const pw.FixedColumnWidth(52),
                  3: const pw.FixedColumnWidth(56),
                  4: const pw.FixedColumnWidth(70),
                  5: const pw.FixedColumnWidth(48),
                  6: const pw.FixedColumnWidth(64),
                  7: const pw.FlexColumnWidth(1),
                  8: const pw.FixedColumnWidth(22),
                },
                border: pw.TableBorder.all(
                  width: 0.5,
                  color: PdfColors.grey400,
                ),
                defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
                children: rows,
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                _t('إجمالي السجلات: ${sorted.length}'),
                style: _s(9, bold: true, color: PdfColors.teal900),
              ),
            ],
          ],
        ),
      );
    }
  }

  /// نص الحالة في صفحة سجل الحصص.
  static String _statusText(int status) {
    switch (status) {
      case AttendanceStatus.present:
        return 'حاضر';
      case AttendanceStatus.absent:
        return 'غائب';
      case AttendanceStatus.leave:
        return 'إجازة';
      case AttendanceStatus.late:
        return 'متأخر';
      default:
        return '—';
    }
  }

  Future<void> _addSummary(
    pw.Document doc,
    List<Lesson> lessons,
  ) async {
    for (final ExportScopeClass sc in classes) {
      final List<pw.TableRow> rows = <pw.TableRow>[
        pw.TableRow(
          children: <pw.Widget>[
            _th(_t('نسبة الحضور')),
            _th(_t('أيام الغياب')),
            _th(_t('إجازة')),
            _th(_t('غياب')),
            _th(_t('متأخر')),
            _th(_t('حاضر')),
            _th(_t('اسم الطالب'), align: pw.Alignment.centerRight, padH: 6),
            _th(_t('ت')),
            for (final Lesson l in lessons) _th(_t('غياب ح${l.slot}'), padH: 2),
          ],
        ),
      ];
      for (int studentIdx = 0; studentIdx < sc.students.length; studentIdx++) {
        final Student s = sc.students[studentIdx];
        final StatusTotals t = await reports.totalsForStudent(s.id, year.id);
        final Map<int, StatusTotals> byLesson =
            await reports.totalsByLesson(s.id, year.id);
        rows.add(
          pw.TableRow(
            children: <pw.Widget>[
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text(
                  '${t.ratePct.toStringAsFixed(1)}%',
                  style: _s(6.5, bold: true),
                ),
              ),
              // «أيام الغياب» مستقل عن «غياب (حصص)»: الأساس القانوني للإنذار.
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text(
                  '${t.absentDays}',
                  style: _s(
                    6.5,
                    bold: t.absentDays > 0,
                    color: t.absentDays > 0
                        ? PdfColors.red900
                        : PdfColors.black,
                  ),
                ),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text('${t.leave}', style: _s(6.5)),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text(
                  '${t.absent}',
                  style: _s(
                    6.5,
                    bold: t.absent > 0,
                    color: t.absent > 0 ? PdfColors.red900 : PdfColors.black,
                  ),
                ),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text('${t.late}', style: _s(6.5)),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text('${t.present}', style: _s(6.5)),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.centerRight,
                padding: const pw.EdgeInsets.symmetric(horizontal: 6),
                child: pw.Text(
                  _t(s.fullName),
                  style: _s(6.5, bold: true),
                  maxLines: 1,
                ),
              ),
              pw.Container(
                height: 16,
                alignment: pw.Alignment.center,
                child: pw.Text('${studentIdx + 1}', style: _s(6.5)),
              ),
              // غياب كل حصة على حدة: «أين» يغيب الطالب لا «كم» فقط.
              for (final Lesson l in lessons)
                pw.Container(
                  height: 16,
                  alignment: pw.Alignment.center,
                  child: pw.Text(
                    '${byLesson[l.id]?.absent ?? 0}',
                    style: _s(6.5),
                  ),
                ),
            ],
          ),
        );
      }
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4.landscape,
          margin: const pw.EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
          header: (pw.Context c) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: <pw.Widget>[
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  pw.Text(
                    _t('نظام حضور الطالب — ملخص السنة الدراسية'),
                    style: _s(8, color: PdfColors.grey700),
                  ),
                  pw.Text(
                    _t(
                      _join(<String>[
                        schoolName,
                        'ملخص السنة',
                        '${sc.cls.grade} ـ ${sc.cls.section}',
                      ]),
                    ),
                    style: _s(11, bold: true, color: PdfColors.teal900),
                  ),
                ],
              ),
              pw.SizedBox(height: 3),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: <pw.Widget>[
                  // «إلى» بدل سهم →: السهم غير موجود في خط التصدير.
                  pw.Text(
                    _t(
                      'السنة الدراسية: ${year.name} '
                      '(${year.start} إلى ${year.end})',
                    ),
                    style: _s(8),
                  ),
                  if (directorName.trim().isNotEmpty)
                    pw.Text(
                      _t('المدير: $directorName'),
                      style: _s(8, bold: true),
                    ),
                ],
              ),
              pw.SizedBox(height: 6),
            ],
          ),
          build: (pw.Context c) => <pw.Widget>[
            if (sc.students.isEmpty)
              pw.Center(
                child: pw.Padding(
                  padding: const pw.EdgeInsets.all(32),
                  child: pw.Text(
                    _t('لا طلاب مسجلون في هذا الصف بعد'),
                    style: _s(10),
                  ),
                ),
              )
            else
              pw.Table(
                columnWidths: <int, pw.TableColumnWidth>{
                  0: const pw.FixedColumnWidth(62),
                  1: const pw.FixedColumnWidth(55),
                  2: const pw.FixedColumnWidth(50),
                  3: const pw.FixedColumnWidth(50),
                  4: const pw.FixedColumnWidth(50),
                  5: const pw.FixedColumnWidth(50),
                  6: const pw.FlexColumnWidth(1),
                  7: const pw.FixedColumnWidth(25),
                  for (int i = 0; i < lessons.length; i++)
                    8 + i: const pw.FixedColumnWidth(34),
                },
                border: pw.TableBorder.all(
                  width: 0.5,
                  color: PdfColors.grey400,
                ),
                defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
                children: rows,
              ),
          ],
        ),
      );
    }
  }

  /// صيغة مهمة الطباعة عرضية مطابقة للصفحات: الافتراضي بورتريه كان
  /// يحتوي الصفحة العرضية بتحجيم وتوسيط فتبدأ بشرائط فارغة.
  Future<void> layout() async {
    final pw.Document doc = await build();
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: 'كشف الحضور والغياب.pdf',
      format: PdfPageFormat.a4.landscape,
    );
  }
}
