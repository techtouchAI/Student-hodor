/// شاشة المسح الميدانية: كاميرا MLKit أوفلاين + منع تكرار + إقفال اليوم.
///
/// حمايات ضد «الشاشة البيضاء/المعلّقة»:
/// - متحكم الكاميرا يُنشأ داخل `try/catch` في `initState` (لا في مُهيّئ حقل)
///   فأي فشل منصة يظهر كرسالة وزر إعادة بدل إسقاط بناء الشاشة كلها.
/// - `WakelockPlus` و`Vibration` ملفوفان بالتقاط (جهاز بلا دعم لا يكسر المسح).
/// - الصف والجلسة يُحلّان من القاعدة مع حالات خطأ ظاهرة.
library;

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/error_guard.dart';
import '../../core/nav.dart';
import '../../core/school_time.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../data/scan_service.dart';
import '../../state/providers.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key, required this.classRef});

  final ClassRef classRef;

  @override
  ConsumerState<ScanScreen> createState() => _ScanState();
}

class _ScanState extends ConsumerState<ScanScreen>
    with WidgetsBindingObserver {
  MobileScannerController? _controller;
  String? _cameraError;
  final Map<String, DateTime> _debounce = <String, DateTime>{};
  final List<ScanOutcome> _feed = <ScanOutcome>[];
  ClassRef? _class;
  Session? _session;
  bool _loading = true;
  String? _notice;
  List<SchoolClass> _options = <SchoolClass>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _createController();
    _keepAwake(true);
    _start(widget.classRef);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final MobileScannerController? controller = _controller;
    if (controller == null) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        if (!controller.value.isRunning) {
          controller.start().catchError((Object e) {});
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        if (controller.value.isRunning) {
          controller.stop().catchError((Object e) {});
        }
    }
  }

  @override
  void didUpdateWidget(ScanScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.classRef.id != widget.classRef.id) {
      _start(widget.classRef);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keepAwake(false);
    _controller?.dispose();
    super.dispose();
  }

  void _createController() {
    try {
      _controller?.dispose();
      _controller = MobileScannerController(
        autoStart: false,
        formats: const <BarcodeFormat>[
          BarcodeFormat.qrCode,
          BarcodeFormat.code128,
        ],
      );
      _cameraError = null;
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'scan:controller');
      _controller = null;
      _cameraError = '$e';
    }
  }

  Future<void> _restartCamera() async {
    final MobileScannerController? c = _controller;
    if (c == null) {
      setState(_createController);
      return;
    }
    try {
      await c.stop();
    } catch (_) {}
    try {
      await c.start();
      if (mounted) {
        setState(() {});
      }
    } catch (e, st) {
      if (e is! MobileScannerException ||
          (e.errorCode != MobileScannerErrorCode.controllerAlreadyInitialized &&
              e.errorCode.name != 'controllerAlreadyInitialized')) {
        AppErrorLog.instance.record(e, st, where: 'scan:restartCamera');
        _snack('تعذر تشغيل الكاميرا: $e');
      }
    }
  }

  Future<void> _keepAwake(bool on) async {
    try {
      if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (e) {
      // جهاز/محاكي بلا دعم wakelock — لا يكسر المسح.
      AppErrorLog.instance.record(e, StackTrace.current, where: 'scan:wakelock');
    }
  }

  Future<void> _start(ClassRef requested) async {
    setState(() {
      _loading = true;
      _notice = null;
    });
    try {
      final AppDb db = ref.read(dbProvider);
      final (int count, ClassRef? resolved) =
          await db.resolveClassRef(requested);
      if (!mounted) {
        return;
      }
      if (resolved == null) {
        _options = await _classesOfActiveYear(db);
        if (!mounted) {
          return;
        }
        setState(() {
          _class = null;
          _session = null;
          _loading = false;
          _notice = count == 0
              ? 'لا توجد صفوف في السنة الفعّالة — أضف صفاً من شاشة الصفوف.'
              : 'لم يُحدَّد صف للمسح.';
        });
        return;
      }
      final AcademicYear? year = await db.activeYear();
      if (!mounted) {
        return;
      }
      if (year == null) {
        setState(() {
          _class = null;
          _session = null;
          _loading = false;
          _notice = 'لا توجد سنة دراسية فعّالة — أنشئها أو فعّلها من شاشة السنوات.';
        });
        return;
      }
      final String date = SchoolTime.dateKey(DateTime.now());
      Session? session = await db.sessionOf(resolved.id, date);
      session ??= await db.into(db.sessions).insertReturning(
            SessionsCompanion(
              yearId: Value(year.id),
              classId: Value(resolved.id),
              date: Value(date),
              openedAt: Value(DateTime.now().toIso8601String()),
            ),
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _class = resolved;
        _session = session;
        _loading = false;
      });
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'scan:session');
      if (mounted) {
        setState(() {
          _loading = false;
          _notice = 'تعذر فتح جلسة اليوم: $e';
        });
      }
    }
  }

  Future<List<SchoolClass>> _classesOfActiveYear(AppDb db) async {
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      return <SchoolClass>[];
    }
    return (db.select(db.schoolClasses)
          ..where((c) => c.yearId.equals(year.id))
          ..orderBy(<OrderClauseGenerator<SchoolClasses>>[
            (SchoolClasses c) => OrderingTerm.asc(c.grade),
            (SchoolClasses c) => OrderingTerm.asc(c.section),
          ]))
        .get();
  }

  Future<void> _pickClass() async {
    if (_options.isEmpty) {
      return;
    }
    final SchoolClass? c = await showDialog<SchoolClass>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('اختر صفاً'),
        children: <Widget>[
          for (final SchoolClass o in _options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Text('${o.grade} ـ ${o.section}'),
            ),
        ],
      ),
    );
    if (c != null) {
      await _start(ClassRef(id: c.id, title: '${c.grade} ـ ${c.section}'));
    }
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _vibrate(bool ok) async {
    try {
      if (await Vibration.hasVibrator()) {
        await Vibration.vibrate(duration: ok ? 90 : 220);
      }
    } catch (e) {
      AppErrorLog.instance.record(e, StackTrace.current, where: 'scan:vibrate');
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    final Session? session = _session;
    if (session == null) {
      return;
    }
    if (session.closedAt != null) {
      _snack('الجلسة مقفلة — أعد فتحها لتسجيل قراءات');
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
      try {
        final ScanOutcome o = await ScanService(ref.read(dbProvider))
            .handleScan(session: session, raw: raw);
        await _vibrate(o.isSuccess);
        if (mounted) {
          setState(() {
            _feed.insert(0, o);
            if (_feed.length > 200) {
              _feed.removeRange(200, _feed.length);
            }
          });
        }
      } catch (e, st) {
        AppErrorLog.instance.record(e, st, where: 'scan:handle');
        if (mounted) {
          setState(() {
            _feed.insert(
              0,
              ScanOutcome(
                result: ScanResult.unknownCode,
                message: 'تعذر تسجيل القراءة: $e',
              ),
            );
          });
        }
      }
    }
  }

  Future<void> _manual() async {
    final Session? session = _session;
    if (session == null) {
      _snack('لا جلسة مفتوحة لهذا الصف');
      return;
    }
    final AppDb db = ref.read(dbProvider);
    List<Student> roster;
    Map<int, int> status;
    try {
      roster = await (db.select(db.students)
            ..where((s) => s.classId.equals(session.classId)))
          .get();
      status = <int, int>{
        for (final AttendanceRow r
            in await db.attendanceForClassDate(session.classId, session.date))
          r.studentId: r.status,
      };
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'scan:manualLoad');
      _snack('تعذر قراءة القائمة: $e');
      return;
    }
    final List<Student> missing = <Student>[
      for (final Student s in roster)
        if (!status.containsKey(s.id)) s,
    ];
    if (!mounted) {
      return;
    }
    if (missing.isEmpty) {
      _snack('كل الطلاب مسجلون');
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
    try {
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
      _snack('سُجّل ${pick.fullName} حاضراً');
      if (mounted) {
        setState(() {});
      }
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'scan:manualSave');
      _snack('تعذر التسجيل: $e');
    }
  }

  Future<void> _toggleClose() async {
    final Session? session = _session;
    if (session == null) {
      _snack('لا جلسة مفتوحة لهذا الصف');
      return;
    }
    final AppDb db = ref.read(dbProvider);
    try {
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
        _snack('أُقفل اليوم وولّد $n سجلاً');
      } else {
        await db.reopenSession(session.id);
        _snack('أُعيد فتح اليوم');
      }
      final Session? refreshed =
          await db.sessionOf(session.classId, session.date);
      if (mounted && refreshed != null) {
        setState(() => _session = refreshed);
      }
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'scan:toggleClose');
      _snack('تعذر تغيير حالة الإقفال: $e');
    }
  }

  Future<int> _missingCount(AppDb db, Session session) async {
    final List<Student> roster = await (db.select(db.students)
          ..where((s) => s.classId.equals(session.classId)))
        .get();
    final int recorded = await db.recordedCount(session.classId, session.date);
    return roster.length - recorded;
  }

  @override
  Widget build(BuildContext context) {
    final ClassRef? c = _class;
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(c == null ? 'مسح الحضور' : 'مسح ${c.displayTitle}'),
        actions: <Widget>[
          if (c != null)
            IconButton(
              tooltip: 'كشف اليوم',
              icon: const Icon(Icons.fact_check),
              onPressed: () => context.push(
                AppRoutes.classLocation('/day-sheet', c.id, c.displayTitle),
                extra: c,
              ),
            ),
          IconButton(
            tooltip: 'الفلاش',
            icon: const Icon(Icons.flashlight_on),
            onPressed: () async {
              try {
                await _controller?.toggleTorch();
              } catch (e) {
                _snack('تعذر تشغيل الفلاش: $e');
              }
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : c == null || _session == null
              ? _NoticeBody(
                  message: _notice ?? 'لا توجد جلسة مسح لهذا الصف.',
                  onPickClass: _options.isEmpty ? null : _pickClass,
                  onRetry: () => _start(widget.classRef),
                  onAddClass: _options.isEmpty
                      ? () => context.pushNamed(AppRoutes.classes)
                      : null,
                )
              : Column(
                  children: <Widget>[
                    _Header(
                      session: _session,
                      classId: c.id,
                      db: db,
                    ),
                    Expanded(flex: 5, child: _camera()),
                    Expanded(
                      flex: 3,
                      child: _feed.isEmpty
                          ? const Center(
                              child: Text(
                                'امسح باج الطالب — ستظهر النتائج هنا فوراً',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView.builder(
                              itemCount: _feed.length,
                              itemBuilder: (BuildContext context, int i) {
                                final ScanOutcome o = _feed[i];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    o.isSuccess
                                        ? Icons.check_circle
                                        : Icons.error,
                                    color: o.isSuccess
                                        ? Colors.green
                                        : Colors.red,
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
                              _session?.closedAt == null
                                  ? Icons.lock
                                  : Icons.lock_open,
                            ),
                            label: Text(
                              _session?.closedAt == null
                                  ? 'إقفال اليوم'
                                  : 'إعادة فتح',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _camera() {
    final MobileScannerController? controller = _controller;
    if (controller == null) {
      return _NoticeBody(
        message: 'تعذر تهيئة الكاميرا: ${_cameraError ?? 'سبب غير معروف'}',
        onRetry: () {
          setState(() {
            _createController();
          });
        },
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        MobileScanner(
          controller: controller,
          onDetect: _onDetect,
          errorBuilder: (
            BuildContext context,
            MobileScannerException error,
            Widget? child,
          ) {
            if (error.errorCode ==
                    MobileScannerErrorCode.controllerAlreadyInitialized ||
                error.errorCode.name == 'controllerAlreadyInitialized') {
              // المتحكم يعمل بالفعل ولا حاجة لعرض شاشة عطل أو تسجيل استثناء كاذب
              return const SizedBox.shrink();
            }
            AppErrorLog.instance.record(
              error,
              StackTrace.current,
              where: 'scan:camera',
            );
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.no_photography, size: 48),
                    const SizedBox(height: 8),
                    Text(
                      error.errorCode ==
                                  MobileScannerErrorCode.permissionDenied ||
                              error.errorCode.name == 'permissionDenied'
                          ? 'صلاحية الكاميرا مرفوضة — فعّلها من إعدادات أندرويد ثم أعد المحاولة'
                          : 'تعذر تشغيل الكاميرا: ${error.errorCode.name}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _restartCamera,
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              ),
            );
          },
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
    );
  }
}

/// جسم بديل واضح (رسالة + أزرار) بدل أي فراغ أبيض.
class _NoticeBody extends StatelessWidget {
  const _NoticeBody({
    required this.message,
    this.onRetry,
    this.onPickClass,
    this.onAddClass,
  });

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onPickClass;
  final VoidCallback? onAddClass;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.info_outline, size: 48),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  if (onPickClass != null)
                    FilledButton.icon(
                      onPressed: onPickClass,
                      icon: const Icon(Icons.class_),
                      label: const Text('اختر صفاً'),
                    ),
                  if (onAddClass != null)
                    FilledButton.icon(
                      onPressed: onAddClass,
                      icon: const Icon(Icons.add),
                      label: const Text('إضافة صف'),
                    ),
                  if (onRetry != null)
                    OutlinedButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة المحاولة'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
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
    return StreamGuard<List<AttendanceRow>>(
      stream: (db.select(db.attendanceRows)
            ..where((a) => a.classId.equals(classId) & a.date.equals(s.date)))
          .watch(),
      loading: const SizedBox(height: 40),
      builder: (BuildContext context, List<AttendanceRow> rows) {
        final int present = rows
            .where(
              (AttendanceRow r) =>
                  r.status == AttendanceStatus.present ||
                  r.status == AttendanceStatus.late,
            )
            .length;
        return StreamGuard<int>(
          stream: (db.selectOnly(db.students)
                ..addColumns(<Expression<int>>[countAll()])
                ..where(db.students.classId.equals(classId)))
              .map((TypedResult r) => r.read(countAll()) ?? 0)
              .watchSingle(),
          loading: Padding(
            padding: const EdgeInsets.all(8),
            child: Text('التاريخ: ${s.date} • حضور: $present / …'),
          ),
          builder: (BuildContext context, int total) => Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                Text('التاريخ: ${s.date}'),
                Text('حضور: $present / $total'),
              ],
            ),
          ),
        );
      },
    );
  }
}
