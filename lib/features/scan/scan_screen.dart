/// شاشة المسح الميدانية: كاميرا MLKit أوفلاين + منع تكرار + إقفال اليوم.
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vibration/vibration.dart';

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

  @override
  void initState() {
    super.initState();
    _openSession();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openSession() async {
    final AppDb db = ref.read(dbProvider);
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return;
    }
    final String date = SchoolTime.dateKey(DateTime.now());
    Session? session = await (db.select(db.sessions)
          ..where((s) => s.classId.equals(widget.classId) & s.date.equals(date)))
        .getSingleOrNull();
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
        setState(() => _feed.insert(0, o));
      }
    }
  }

  Future<void> _manual() async {
    final Session? session = _session;
    if (session == null) {
      return;
    }
    final AppDb db = ref.read(dbProvider);
    final List<(Student, int?)> matrix = await _matrix(db, session);
    final List<Student> missing = <Student>[
      for (final (Student s, int? st) in matrix)
        if (st == null) s,
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
    setState(() {});
  }

  Future<List<(Student, int?)>> _matrix(AppDb db, Session session) async {
    final List<Student> roster = await (db.select(db.students)
          ..where((s) => s.classId.equals(session.classId)))
        .get();
    final Map<int, int> status = <int, int>{
      for (final AttendanceRow r in await (db.select(db.attendanceRows)
            ..where((a) => a.classId.equals(session.classId) & a.date.equals(session.date)))
          .get())
        r.studentId: r.status,
    };
    return <(Student, int?)>[for (final Student s in roster) (s, status[s.id])];
  }

  Future<void> _toggleClose() async {
    final Session? session = _session;
    if (session == null) {
      return;
    }
    final AppDb db = ref.read(dbProvider);
    if (session.closedAt == null) {
      final List<(Student, int?)> matrix = await _matrix(db, session);
      final int missing = matrix.where((e) => e.$2 == null).length;
      if (!context.mounted) {
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
    final Session refreshed = await (db.select(db.sessions)
          ..where((s) => s.id.equals(session.id)))
        .getSingle();
    setState(() => _session = refreshed);
  }

  @override
  Widget build(BuildContext context) {
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('مسح ${widget.title}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'الفلاش',
            icon: const Icon(Icons.flashlight_on),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: _loadingSession
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                _Header(session: _session, classId: widget.classId, db: db),
                Expanded(
                  flex: 5,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      MobileScanner(controller: _controller, onDetect: _onDetect),
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
                        label: Text(_session?.closedAt == null ? 'إقفال اليوم' : 'إعادة فتح'),
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
