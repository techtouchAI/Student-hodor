/// شاشة المسح الميدانية: كاميرا MLKit أوفلاين + منع تكرار + إقفال اليوم.
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/scan_service.dart';
import '../../state/providers.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key, required this.classId, required this.title});

  final int classId;
  final String title;

  @override
  ConsumerState<ScanScreen> createState() => _ScanState();
}

class _ScanState extends ConsumerState<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode, BarcodeFormat.code128],
  );
  final Map<String, DateTime> _debounce = <String, DateTime>{};
  final List<ScanOutcome> _feed = <ScanOutcome>[];
  Session? _session;
  bool _loadingSession = true;
  bool _noYear = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _openSession();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openSession() async {
    final AppDb db = ref.read(dbProvider);
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      if (mounted) {
        setState(() {
          _noYear = true;
          _loadingSession = false;
        });
      }
      return;
    }
    final String date = SchoolTime.dateKey(DateTime.now());
    Session? session = await db.sessionOf(widget.classId, date);
    session ??= await db
        .into(db.sessions)
        .insertReturning(
          SessionsCompanion(
            yearId: Value(year.id),
            classId: Value(widget.classId),
            date: Value(date),
            openedAt: Value(DateTime.now().toIso8601String()),
          ),
        );
    if (mounted) {
      setState(() {
        _session = session;
        _loadingSession = false;
      });
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    final Session? session = _session;
    if (session == null || session.closedAt != null) {
      return;
    }
    for (final Barcode b in capture.barcodes) {
      final String? raw = b.rawValue;
      if (raw == null || raw.isEmpty) {
        continue;
      }
      final DateTime last = _debounce[raw] ?? DateTime(2000);
      if (DateTime.now().difference(last).inMilliseconds < 2500) {
        continue;
      }
      _debounce[raw] = DateTime.now();
      final ScanOutcome o =
          await ScanService(ref.read(dbProvider)).handleScan(session: session, raw: raw);
      if (await Vibration.hasVibrator()) {
        await Vibration.vibrate(duration: o.isSuccess ? 90 : 220);
      }
      if (mounted) {
        setState(() {
          _feed.insert(0, o);
          if (_feed.length > 200) {
            _feed.removeRange(200, _feed.length);
          }
        });
      }
    }
  }

  Future<void> _manual() async {
    final Session? session = _session;
    if (session == null) {
      return;
    }
    final AppDb db = ref.read(dbProvider);
    final List<Student> roster = await (db.select(db.students)
          ..where((s) => s.classId.equals(session.classId)))
        .get();
    final Map<int, int> status = <int, int>{
      for (final AttendanceRow r
          in await db.attendanceForClassDate(session.classId, session.date))
        r.studentId: r.status,
    };
    final List<Student> missing = <Student>[
      for (final Student s in roster)
        if (!status.containsKey(s.id)) s,
    ];
    if (!mounted) {
      return;
    }
    if (missing.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('كل الطلاب مسجلون')));
      return;
    }
    final Student? pick = await showDialog<Student>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('تسجيل حضور يدوي'),
        children: <Widget>[
          for (final Student s in missing)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, s),
              child: Text(s.fullName),
            ),
        ],
      ),
    );
    if (pick == null) {
      return;
    }
    await db.upsertAttendance(
      yearId: session.yearId,
      classId: session.classId,
      studentId: pick.id,
      date: session.date,
      status: AttendanceStatus.present,
      source: AttendanceSource.manual,
      sessionId: session.id,
    );
    await db.logAudit('manual_present', pick.fullName);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _toggleClose() async {
    final Session? session = _session;
    if (session == null) {
      return;
    }
    final AppDb db = ref.read(dbProvider);
    if (session.closedAt == null) {
      final int missing = await _missingCount(db, session);
      if (!mounted) {
        return;
      }
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('إقفال اليوم'),
          content: Text(
            'سيُسجل $missing طالباً كغائبين (أو بإجازة إن وجدت). '
            'يمكن إعادة الفتح لاحقاً لتصحيح الأخطاء.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('تراجع'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('أقفل اليوم'),
            ),
          ],
        ),
      );
      if (ok != true) {
        return;
      }
      final int n = await db.closeSession(session.id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('أُقفل اليوم وولّد $n سجلاً')));
      }
    } else {
      await db.reopenSession(session.id);
    }
    final Session? refreshed =
        await db.sessionOf(session.classId, session.date);
    if (mounted && refreshed != null) {
      setState(() => _session = refreshed);
    }
  }

  Future<int> _missingCount(AppDb db, Session session) async {
    final List<Student> roster = await (db.select(db.students)
          ..where((s) => s.classId.equals(session.classId)))
        .get();
    final int recorded =
        await db.recordedCount(session.classId, session.date);
    return roster.length - recorded;
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('مسح ${widget.title}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'كشف اليوم',
            icon: const Icon(Icons.fact_check),
            onPressed: () => context.push(
              '/day-sheet?class=${widget.classId}'
              '&title=${Uri.encodeComponent(widget.title)}',
            ),
          ),
          IconButton(
            tooltip: 'الفلاش',
            icon: const Icon(Icons.flashlight_on),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: _loadingSession
          ? const Center(child: CircularProgressIndicator())
          : _noYear
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'لا توجد سنة دراسية فعّالة.\nأنشئ سنة أو فعّلها من شاشة السنوات.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Column(
                  children: <Widget>[
                    _Header(session: _session, classId: widget.classId, db: db),
                    Expanded(
                      flex: 5,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          MobileScanner(
                            controller: _controller,
                            onDetect: _onDetect,
                            errorBuilder: (
                              BuildContext context,
                              MobileScannerException error,
                              Widget? child,
                            ) =>
                                Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    const Icon(Icons.no_photography, size: 48),
                                    const SizedBox(height: 8),
                                    Text(
                                      error.errorCode.name == 'permissionDenied'
                                          ? 'صلاحية الكاميرا مرفوضة — فعّلها من إعدادات أندرويد ثم أعد المحاولة'
                                          : 'تعذر تشغيل الكاميرا: ${error.errorCode}',
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 12),
                                    FilledButton(
                                      onPressed: () => _controller.start(),
                                      child: const Text('إعادة المحاولة'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (_session?.closedAt != null)
                            const ColoredBox(
                              color: Color(0xAA000000),
                              child: Center(
                                child: Text(
                                  'الجلسة مقفلة — أعد فتحها لتسجيل قراءات',
                                  style: TextStyle(color: Colors.white, fontSize: 18),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: ListView.builder(
                        itemCount: _feed.length,
                        itemBuilder: (BuildContext context, int i) {
                          final ScanOutcome o = _feed[i];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              o.isSuccess ? Icons.check_circle : Icons.error,
                              color: o.isSuccess ? Colors.green : Colors.red,
                            ),
                            title: Text(o.message),
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: <Widget>[
                          FilledButton.icon(
                            onPressed: _manual,
                            icon: const Icon(Icons.edit),
                            label: const Text('يدوي'),
                          ),
                          FilledButton.icon(
                            onPressed: _toggleClose,
                            icon: Icon(
                              _session?.closedAt == null ? Icons.lock : Icons.lock_open,
                            ),
                            label: Text(
                              _session?.closedAt == null ? 'إقفال اليوم' : 'إعادة فتح',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.session, required this.classId, required this.db});

  final Session? session;
  final int classId;
  final AppDb db;

  @override
  Widget build(BuildContext context) {
    final Session? s = session;
    if (s == null) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<List<AttendanceRow>>(
      stream: (db.select(db.attendanceRows)
            ..where((a) => a.classId.equals(classId) & a.date.equals(s.date)))
          .watch(),
      builder: (BuildContext context, AsyncSnapshot<List<AttendanceRow>> snap) {
        final List<AttendanceRow> rows = snap.data ?? <AttendanceRow>[];
        final int present = rows
            .where(
              (AttendanceRow r) =>
                  r.status == AttendanceStatus.present ||
                  r.status == AttendanceStatus.late,
            )
            .length;
        return StreamBuilder<int>(
          stream: (db.selectOnly(db.students)
                ..addColumns(<Expression<int>>{countAll()})
                ..where(db.students.classId.equals(classId)))
              .map((TypedResult r) => r.read(countAll()) ?? 0)
              .watchSingle(),
          builder: (BuildContext context, AsyncSnapshot<int> total) => Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                Text('التاريخ: ${s.date}'),
                Text('حضور: $present / ${total.data ?? 0}'),
              ],
            ),
          ),
        );
      },
    );
  }
}
