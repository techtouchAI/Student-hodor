/// ملف الطالب التفصيلي: مجاميع، شبكة شهر ملوّنة، إجازات، مسيرة سنوات.
///
/// العطل الذي كان يُبقي الشاشة «تحمّل إلى الأبد»:
/// `StreamBuilder` على تدفق `drift` **لا يصل أبداً** إلى `ConnectionState.done`
/// (التدفق يبقى مفتوحاً ليعيد البث عند كل تغيير، فتكون الحالة `active` لا
/// `done`)، وكان الشرط `if (connectionState != ConnectionState.done)` يمنع
/// بناء الجسم نهائياً فيبقى المؤشر يدور. القاعدة الآن في كل التطبيق:
/// الاعتماد على **وصول أول حدث** (`StreamGuard` في `core/error_guard.dart`) لا
/// على نهاية التدفق.
///
/// كذلك جُمعت بيانات الملف (المجاميع/الخلايا/الإجازات/المسيرة) في **مستقبل
/// واحد** يُحسب مرة لكل تغيّر (طالب/سنة/شهر) بدل أربعة `FutureBuilder` تُنشئ
/// استعلامات جديدة عند كل إعادة بناء — أبطأ وأسهل في ظهور «تحميل» متقطع.
///
/// النقر على أي يوم في الشبكة يعرض تاريخه ويسمح بتغيير حالته (حاضر/
/// غائب/إجازة/متأخر) أو مسح تسجيله، وزر التنزيل في الأعلى يصدّر سجل
/// الطالب الكامل (من بداية السنة حتى اليوم) Excel أو PDF مع الإحصائيات.
library;

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../core/attendance_labels.dart';
import '../../core/error_guard.dart';
import '../../core/late_time.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../data/reports_service.dart';
import '../../state/providers.dart';
import '../attendance/late_time_picker.dart';
import '../export/excel_builder.dart';
import '../export/student_record_pdf.dart';

class StudentReportScreen extends ConsumerWidget {
  const StudentReportScreen({super.key, required this.studentId});

  final int studentId;

  /// تنزيل سجل الطالب الكامل: اختيار الصيغة ثم البناء والمشاركة/الطباعة.
  Future<void> _download(BuildContext context, WidgetRef ref) async {
    final AppDb db = ref.read(dbProvider);
    final Student? student = await db.studentById(studentId);
    if (!context.mounted) {
      return;
    }
    if (student == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الطالب غير موجود (ربما حُذف)')),
      );
      return;
    }
    final String? format = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('تنزيل سجل الطالب الكامل'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'excel'),
            child: const Text('ملف Excel'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'pdf'),
            child: const Text('ملف PDF'),
          ),
        ],
      ),
    );
    if (format == null || !context.mounted) {
      return;
    }
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) =>
            const Center(child: CircularProgressIndicator()),
      ),
    );
    try {
      if (format == 'excel') {
        await _downloadExcel(db, student);
      } else {
        await _downloadPdf(db, student);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر التنزيل: $e')),
        );
      }
    } finally {
      if (context.mounted) {
        Navigator.pop(context);
      }
    }
  }

  Future<(AcademicYear, Set<int>, Set<String>, String)> _recordScope(
    AppDb db,
    Student student,
  ) async {
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      throw StateError('لا سنة فعّالة');
    }
    final Map<String, String> settings = await db.effectiveSettings();
    final Set<int> weekdays = <int>{
      for (final String w
          in (settings['work_weekdays'] ?? '7,1,2,3,4').split(','))
        int.tryParse(w) ?? 0,
    };
    final Set<String> holidays = <String>{
      for (final Holiday h in await db.select(db.holidays).get()) h.date,
    };
    final String classTitle = await db.classTitle(student.classId) ?? '';
    return (year, weekdays, holidays, classTitle);
  }

  Future<void> _downloadExcel(AppDb db, Student student) async {
    final (AcademicYear year, Set<int> weekdays, Set<String> holidays,
        String classTitle) = await _recordScope(db, student);
    final Map<String, String> settings = await db.effectiveSettings();
    final ExcelBuilder builder = ExcelBuilder.studentRecord(
      db: db,
      reports: ReportsService(db),
      schoolName: settings['school_name'] ?? '',
      directorName: settings['director_name'] ?? '',
      year: year,
      workWeekdays: weekdays,
      holidayKeys: holidays,
    );
    final List<int> bytes = await builder.buildStudentRecord(
      student: student,
      classTitle: classTitle,
    );
    final String fileName = ExcelBuilder.recordFileName(
      studentName: student.fullName,
      yearName: year.name,
    );
    final File f = File('${Directory.systemTemp.path}/$fileName');
    await f.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(f.path)]),
    );
  }

  Future<void> _downloadPdf(AppDb db, Student student) async {
    final (AcademicYear year, Set<int> weekdays, Set<String> holidays,
        String classTitle) = await _recordScope(db, student);
    final Map<String, String> settings = await db.effectiveSettings();
    final StudentRecordPdf record = StudentRecordPdf(
      reports: ReportsService(db),
      schoolName: settings['school_name'] ?? '',
      directorName: settings['director_name'] ?? '',
      year: year,
      student: student,
      classTitle: classTitle,
      workWeekdays: weekdays,
      holidayKeys: holidays,
      font: pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Regular.ttf')),
      fontBold: pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Bold.ttf')),
    );
    await record.layout();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('ملف الطالب'),
        actions: <Widget>[
          IconButton(
            tooltip: 'تنزيل سجل الطالب الكامل',
            icon: const Icon(Icons.download),
            onPressed: () => _download(context, ref),
          ),
        ],
      ),
      body: StreamGuard<Student?>(
        stream: (db.select(db.students)
              ..where((s) => s.id.equals(studentId)))
            .watchSingleOrNull(),
        builder: (BuildContext context, Student? student) {
          if (student == null) {
            return const Center(child: Text('الطالب غير موجود (ربما حُذف)'));
          }
          return _ReportBody(db: db, student: student);
        },
      ),
    );
  }
}

/// كل ما تحتاجه الشاشة في حزمة واحدة محسوبة مرة لكل (طالب، سنة، شهر).
class _FileData {
  const _FileData({
    required this.yearName,
    required this.totals,
    required this.cells,
    required this.leaves,
    required this.journey,
  });

  final String yearName;
  final StatusTotals totals;
  final List<DayCell> cells;
  final List<Leave> leaves;
  final List<(AcademicYear, StatusTotals)> journey;
}

class _ReportBody extends StatefulWidget {
  const _ReportBody({required this.db, required this.student});

  final AppDb db;
  final Student student;

  @override
  State<_ReportBody> createState() => _ReportBodyState();
}

class _ReportBodyState extends State<_ReportBody> {
  late int _year;
  late int _month;
  Future<_FileData?>? _load;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _year = now.year;
    _month = now.month;
    _load = _loadFile();
  }

  @override
  void didUpdateWidget(_ReportBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.student.id != widget.student.id) {
      setState(() => _load = _loadFile());
    }
  }

  /// `null` تعني «لا سنة دراسية فعّالة» (لا يمكن حساب مجاميع السنة).
  Future<_FileData?> _loadFile() async {
    final AppDb db = widget.db;
    final Student student = widget.student;
    // لقطة للشهر المطلوب قبل أي `await`: ضغطتان سريعتان على مفتاح التنقّل لا
    // تُنتجان شهرين مختلفين داخل تحميلين متزامنين.
    final int wantedYear = _year;
    final int wantedMonth = _month;
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return null;
    }
    final ReportsService reports = ReportsService(db);
    final Map<String, String> settings = await db.effectiveSettings();
    final Set<int> weekdays = <int>{
      for (final String w
          in (settings['work_weekdays'] ?? '7,1,2,3,4').split(','))
        int.tryParse(w) ?? 0,
    };
    final Set<String> holidays = <String>{
      for (final Holiday h in await db.select(db.holidays).get()) h.date,
    };
    final StatusTotals totals =
        await reports.totalsForStudent(student.id, year.id);
    final List<DayCell> cells = await reports.monthCells(
      studentId: student.id,
      yearId: year.id,
      year: wantedYear,
      month: wantedMonth,
      workWeekdays: weekdays,
      holidayKeys: holidays,
    );
    final List<Leave> leaves = await (db.select(db.leaves)
          ..where((l) => l.studentId.equals(student.id))
          ..orderBy(<OrderClauseGenerator<Leaves>>[
            (Leaves l) => OrderingTerm.desc(l.start),
          ]))
        .get();
    final List<(AcademicYear, StatusTotals)> journey =
        await reports.studentJourney(student);
    return _FileData(
      yearName: year.name,
      totals: totals,
      cells: cells,
      leaves: leaves,
      journey: journey,
    );
  }

  void _reload() => setState(() => _load = _loadFile());

  /// تعديل يوم من الشبكة: يعرض التاريخ المحدد ويسمح بتغيير حالته أو
  /// مسح تسجيله — تسجيل يدوي صريح من المدير.
  Future<void> _editDay(DayCell cell) async {
    final AppDb db = widget.db;
    final Student student = widget.student;
    final DateTime d = SchoolTime.parseKey(cell.dateKey);
    final int? picked = await showDialog<int?>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(SchoolTime.formatFullAr(d)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // سجل التأخر يعرض وقته الفعلي المثبت في القاعدة لا اسمه وحده.
            Text(
              'الحالة الحالية: '
              '${cell.status == AttendanceStatus.late ? lateInfoLabel(arrivalTime: cell.arrivalTime) : statusName(cell.status)}',
            ),
            if (!cell.isSchoolDay)
              const Text(
                'يوم عطلة — أي تسجيل هنا يدوي صريح.',
                style: TextStyle(color: Colors.grey),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final int st in <int>[
                  AttendanceStatus.present,
                  AttendanceStatus.absent,
                  AttendanceStatus.leave,
                  AttendanceStatus.late,
                ])
                  ChoiceChip(
                    label: Text(statusName(st)),
                    selected: cell.status == st,
                    onSelected: (_) => Navigator.pop(context, st),
                  ),
              ],
            ),
          ],
        ),
        actions: <Widget>[
          if (cell.status != null)
            TextButton(
              onPressed: () => Navigator.pop(context, -1),
              child: const Text(
                'مسح التسجيل',
                style: TextStyle(color: Colors.red),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    if (picked == -1) {
      await db.deleteAttendance(student.id, cell.dateKey);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('مُسح تسجيل اليوم')),
      );
      _reload();
      return;
    }
    if (picked == cell.status) {
      return;
    }
    // تأخر يدوي ⇒ اسأل عن وقت الوصول (ساعة ودقيقة) ليُثبّت مع السجل؛
    // إلغاء المنتقي يحفظ التأخر بلا وقت بدل تعطيل التصحيح.
    String? arrival;
    if (picked == AttendanceStatus.late) {
      arrival = await pickManualArrivalTime(context);
      if (!mounted) {
        return;
      }
    }
    final Session? session =
        await db.sessionOf(student.classId, cell.dateKey);
    if (!mounted) {
      return;
    }
    await db.upsertAttendance(
      yearId: student.yearId,
      classId: student.classId,
      studentId: student.id,
      date: cell.dateKey,
      status: picked,
      source: AttendanceSource.manual,
      sessionId: session?.id,
      arrivalTime: arrival,
    );
    if (!mounted) {
      return;
    }
    final String saved = picked == AttendanceStatus.late
        ? lateInfoLabel(arrivalTime: arrival)
        : statusName(picked);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('حُفظت الحالة: $saved')),
    );
    _reload();
  }

  /// تنقّل بين الأشهر (−1 للسابق، +1 للتالي) مع إعادة حساب خلايا الشهر.
  void _shiftMonth(int delta) {
    setState(() {
      int month = _month + delta;
      int year = _year;
      if (month < 1) {
        month = 12;
        year--;
      } else if (month > 12) {
        month = 1;
        year++;
      }
      _month = month;
      _year = year;
      _load = _loadFile();
    });
  }

  @override
  Widget build(BuildContext context) {
    final Student student = widget.student;
    return FutureBuilder<_FileData?>(
      future: _load,
      builder: (BuildContext context, AsyncSnapshot<_FileData?> snap) {
        if (snap.hasError) {
          AppErrorLog.instance.record(
            snap.error!,
            snap.stackTrace ?? StackTrace.current,
            where: 'studentReport:load',
          );
          return Center(
            child: LoadErrorCard(message: '${snap.error}', onRetry: _reload),
          );
        }
        // `FutureBuilder` (لا `StreamBuilder`): `done` هنا تعني فعلاً اكتمل.
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final _FileData? data = snap.data;
        if (data == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'لا توجد سنة دراسية فعّالة — أنشئها أو فعّلها من شاشة السنوات',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            // قابل للتمرير دائماً حتى يسحب المستخدم للتحديث وإن كان المحتوى قصيراً.
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              Text(
                student.fullName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                'رقم الطالب: ${student.seq}',
                textAlign: TextAlign.center,
              ),
              Text(
                'السنة الدراسية: ${data.yearName}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              _TotalsCard(totals: data.totals),
              const SizedBox(height: 8),
              _MonthGrid(
                year: _year,
                month: _month,
                cells: data.cells,
                onPrevious: () => _shiftMonth(-1),
                onNext: () => _shiftMonth(1),
                onDayTap: _editDay,
              ),
              const SizedBox(height: 12),
              const _Legend(),
              const SizedBox(height: 12),
              _LeavesCard(leaves: data.leaves),
              const SizedBox(height: 12),
              _JourneyCard(journey: data.journey),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals});

  final StatusTotals totals;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: <Widget>[
              _Stat('حضور', totals.present, Colors.green),
              _Stat('غياب', totals.absent, Colors.red),
              _Stat('إجازة', totals.leave, Colors.amber),
              _Stat('متأخر', totals.late, Colors.orange),
              _Stat('النسبة', totals.ratePct.round(), Colors.teal),
            ],
          ),
        ),
      );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(label, textAlign: TextAlign.center),
        ],
      );
}

/// شبكة الشهر + مفتاح التنقّل بين الأشهر.
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.year,
    required this.month,
    required this.cells,
    required this.onPrevious,
    required this.onNext,
    required this.onDayTap,
  });

  final int year;
  final int month;
  final List<DayCell> cells;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<DayCell> onDayTap;

  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                tooltip: 'الشهر السابق',
                icon: const Icon(Icons.chevron_right),
                onPressed: onPrevious,
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${SchoolTime.monthNames[month - 1]} $year',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'الشهر التالي',
                icon: const Icon(Icons.chevron_left),
                onPressed: onNext,
              ),
            ],
          ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: <Widget>[
              for (final DayCell c in cells)
                Tooltip(
                  // تلميح اليوم المتأخر يشمل وقته الفعلي المثبت في السجل.
                  message: '${c.dateKey}: '
                      '${c.status == AttendanceStatus.late ? lateInfoLabel(arrivalTime: c.arrivalTime) : statusName(c.status)}',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onDayTap(c),
                    child: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.isSchoolDay
                            ? statusColor(c.status)
                            : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${SchoolTime.parseKey(c.dateKey).day}',
                        style: TextStyle(
                          color: c.isSchoolDay ? Colors.white : Colors.black54,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
}

/// مفتاح الألوان — يوضّح معنى كل مربع في الشبكة.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 10,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: <Widget>[
          const _LegendItem(Colors.green, 'حاضر'),
          const _LegendItem(Colors.red, 'غائب'),
          const _LegendItem(Colors.amber, 'إجازة'),
          const _LegendItem(Colors.orange, 'متأخر'),
          _LegendItem(Colors.grey.shade300, 'عطلة/ليس دوام'),
          const _LegendItem(Colors.grey, 'لم يُسجَّل'),
        ],
      );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem(this.color, this.label);

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

class _LeavesCard extends StatelessWidget {
  const _LeavesCard({required this.leaves});

  final List<Leave> leaves;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'الإجازات',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              if (leaves.isEmpty) const Text('لا إجازات'),
              for (final Leave l in leaves)
                Text('${l.start} → ${l.end} (${l.reason})'),
            ],
          ),
        ),
      );
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({required this.journey});

  final List<(AcademicYear, StatusTotals)> journey;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'مسيرة الطالب عبر السنوات',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              if (journey.isEmpty) const Text('لا سجلات سابقة'),
              for (final (AcademicYear y, StatusTotals t) in journey)
                Text(
                  '${y.name}: حضور ${t.present + t.late}، غياب ${t.absent}، '
                  'إجازة ${t.leave} — نسبة ${t.ratePct.toStringAsFixed(1)}%',
                ),
            ],
          ),
        ),
      );
}
