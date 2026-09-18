/// شاشة المسح الميدانية: كاميرا MLKit أوفلاين + منع تكرار + إقفال اليوم.
///
/// حمايات ضد «الشاشة السوداء/الكاميرا المتأخرة»:
/// - الكاميرا تُشغَّل **فوراً في `initState` وبالتوازي** مع فتح جلسة اليوم من
///   القاعدة. سابقاً كان المتحكم يُنشأ بـ`autoStart: false` ولا أحد يستدعي
///   `start()` (ودجت `MobileScanner` يشغّل الكاميرا فقط عندما يكون
///   `autoStart: true`) ⇒ تبقى الشاشة سوداء حتى يصادف التطبيق حدث
///   `resumed` (خلفية/أمامية)، وهذا سبب «تتأخر كثيراً حتى تظهر».
/// - `placeholderBuilder` يعرض «جارٍ تشغيل الكاميرا» بدل المربع الأسود
///   الافتراضي الذي يرسمه `mobile_scanner` قبل اكتمال التهيئة.
/// - إعادة محاولة محدودة للتهيئة: عطل معروف في `mobile_scanner 5.2.3` ينتج
///   شاشة سوداء بلا رسالة خطأ، ويُصلح هنا بالتحقق من `value.isRunning` بعد كل
///   محاولة ثم `stop()` (يمسح حالة الخطأ) و`start()` من جديد.
/// - الفلاش يتحقق أن الكاميرا **تعمل** وأن الجهاز **يدعم** الفلاش قبل
///   `toggleTorch()`؛ سابقاً كان `toggleTorch()` على متحكم غير مهيّأ يرمي
///   `controllerUninitialized` فتظهر رسالة خطأ والفلاش لا يعمل.
/// - دورة الحياة: لا إيقاف للكاميرا عند `inactive` (يفقده أندرويد لأي نافذة
///   عابرة: طلب صلاحية، شريط إشعارات) بل عند `paused/hidden/detached` فقط.
library;

import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/error_guard.dart';
import '../../core/late_time.dart';
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
  /// عدد محاولات تهيئة الكاميرا قبل إعلان العطل (التهيئة الأولى قد تتعثر).
  static const int _startAttempts = 3;

  /// أخطاء لا تنفع معها إعادة المحاولة: صلاحية مرفوضة (يحتاج إعدادات النظام)
  /// أو متحكم مُتلف. تُقارن بالاسم حتى لا ننكسر إن تغيّرت أعضاء العدد.
  static const Set<String> _noRetryCodes = <String>{
    'permissionDenied',
    'controllerDisposed',
  };

  MobileScannerController? _controller;
  String? _cameraError;

  /// محاولة تشغيل جارية — يُنتظر مستقبلها بدل إطلاق محاولة موازية
  /// (تشغيلان متزامنان ينتجان `controllerAlreadyInitialized`).
  Future<void>? _cameraStartTask;

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
    // الكاميرا أولاً وبالتوازي مع القاعدة: لا انتظار لفتح جلسة اليوم.
    unawaited(_startCamera());
    unawaited(_keepAwake(true));
    unawaited(_start(widget.classRef));
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
          unawaited(_startCamera());
        }
      case AppLifecycleState.inactive:
        // لا إيقاف هنا: `inactive` يُطلقه أندرويد لأي فقد تركيز عابر
        // (نافذة الصلاحية، شريط الإشعارات، مكالمة) وإيقاف الكاميرا عنده كان
        // يعني شاشة سوداء/إعادة تهيئة بطيئة عند كل حدث صغير.
        return;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (controller.value.isRunning) {
          _stopController(controller);
        }
    }
  }

  @override
  void didUpdateWidget(ScanScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.classRef.id != widget.classRef.id) {
      unawaited(_start(widget.classRef));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_keepAwake(false));
    final MobileScannerController? controller = _controller;
    _controller = null;
    if (controller != null) {
      _disposeController(controller);
    }
    super.dispose();
  }

  /// إتلاف/إيقاف بلا تسريب عطل: على جهاز بلا كاميرا (أو في الاختبارات) ترمي
  /// قناة المنصة استثناءً داخل مستقبل غير مُنتظَر فينهار الإطار كله بسببه.
  void _disposeController(MobileScannerController c) {
    unawaited(
      c.dispose().catchError((Object e) {
        AppErrorLog.instance.record(e, StackTrace.current, where: 'scan:dispose');
      }),
    );
  }

  void _stopController(MobileScannerController c) {
    unawaited(
      c.stop().catchError((Object e) {
        AppErrorLog.instance.record(e, StackTrace.current, where: 'scan:stop');
      }),
    );
  }

  // ---------------- الكاميرا ----------------

  void _createController() {
    final MobileScannerController? old = _controller;
    if (old != null) {
      _disposeController(old);
    }
    try {
      _controller = MobileScannerController(
        // التشغيل يدوي (انظر `_startCamera`) حتى لا يوقف ودجت `MobileScanner`
        // الكاميرا عند كل إعادة بناء للجسم.
        autoStart: false,
        detectionSpeed: DetectionSpeed.normal,
        detectionTimeoutMs: 250,
        facing: CameraFacing.back,
        // صيغتا الباج فقط (QR + Code128): أقل صيغاً ⇒ كشف أسرع.
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

  /// يشغّل الكاميرا (أو ينتظر محاولة جارية).
  Future<void> _startCamera() {
    final Future<void>? inFlight = _cameraStartTask;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<void> task = _runCameraStart().whenComplete(() {
      _cameraStartTask = null;
    });
    _cameraStartTask = task;
    return task;
  }

  Future<void> _runCameraStart() async {
    final MobileScannerController? c = _controller;
    if (c == null) {
      return;
    }
    for (int attempt = 1; attempt <= _startAttempts; attempt++) {
      if (!mounted || !identical(_controller, c)) {
        return;
      }
      try {
        await c.start();
      } catch (e, st) {
        // `start()` لا يرمي عادةً (يخزّن الخطأ في `value.error`) لكنه قد يرمي
        // إن كان المتحكم مُتلفاً أو قناة المنصة غير جاهزة.
        AppErrorLog.instance.record(e, st, where: 'scan:start');
        _cameraError = _cameraMessage(e);
      }
      if (!mounted || !identical(_controller, c)) {
        return;
      }
      final MobileScannerState value = c.value;
      if (value.isRunning) {
        _cameraError = null;
        break;
      }
      final MobileScannerException? error = value.error;
      if (error != null) {
        _cameraError = _cameraMessage(error);
        AppErrorLog.instance.record(error, StackTrace.current, where: 'scan:start');
        if (_noRetryCodes.contains(error.errorCode.name)) {
          // صلاحية مرفوضة/متحكم مُتلف: إعادة المحاولة الآلية لا تفيد.
          break;
        }
      }
      // `stop()` يمسح حالة الخطأ المخزّنة فيسمح بطلب الصلاحية/التهيئة من جديد.
      try {
        await c.stop();
      } catch (_) {}
      if (attempt < _startAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// إعادة تهيئة كاملة (زر «إعادة المحاولة»): متحكم جديد ثم تشغيل.
  Future<void> _resetCamera() async {
    setState(_createController);
    await _startCamera();
  }

  String _cameraMessage(Object error) {
    if (error is MobileScannerException) {
      if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
        return 'صلاحية الكاميرا مرفوضة — فعّلها من إعدادات أندرويد ثم أعد المحاولة';
      }
      final String? details = error.errorDetails?.message;
      return details == null || details.isEmpty
          ? 'تعذر تشغيل الكاميرا (${error.errorCode.name})'
          : 'تعذر تشغيل الكاميرا: $details';
    }
    return '$error';
  }

  /// الفلاش: يشغّل الكاميرا إن كانت متوقفة، ويرفض برسالة واضحة إن كان الجهاز
  /// بلا فلاش — بدل استثناء `controllerUninitialized` الخام.
  Future<void> _toggleTorch() async {
    final MobileScannerController? c = _controller;
    if (c == null) {
      _snack('الكاميرا غير مهيّأة — اضغط «إعادة المحاولة»');
      return;
    }
    try {
      if (!c.value.isRunning) {
        await _startCamera();
        if (!mounted) {
          return;
        }
        if (!c.value.isRunning) {
          _snack('شغّل الكاميرا أولاً ثم أعد محاولة الفلاش');
          return;
        }
      }
      if (c.value.torchState == TorchState.unavailable) {
        _snack('هذا الجهاز لا يدعم الفلاش');
        return;
      }
      await c.toggleTorch();
      if (mounted) {
        setState(() {});
      }
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'scan:torch');
      if (!mounted) {
        return;
      }
      _snack('تعذر تشغيل الفلاش: ${_cameraMessage(e)}');
    }
  }

  // ---------------- الجلسة ----------------

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
        // التسجيل اليدوي يحدث «الآن» — يثبّت وقته الفعلي كوقت وصول.
        arrivalTime: arrivalTimeString(DateTime.now()),
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

  // ---------------- الواجهة ----------------

  @override
  Widget build(BuildContext context) {
    final ClassRef? c = _class;
    final Session? session = _session;
    // تُحسب قبل `ready`: تحليل التدفق يرقّي `session` عبر المتغير المنطقي،
    // فتصير `session?.` تحذير invalid_null_aware_operator في الشجرة أدناه.
    final String? closedAt = session?.closedAt; // عمود نصي (ISO) في drift
    final AppDb db = ref.watch(dbProvider);
    final bool ready = !_loading && c != null && session != null;
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
          _torchButton(),
        ],
      ),
      // الكاميرا مبنية دائماً (لا خلف مؤشر تحميل): تبدأ التهيئة فور فتح الشاشة
      // بالتوازي مع قراءة القاعدة، وأي رسالة/عطل طبقة فوق المعاينة.
      body: Column(
        children: <Widget>[
          _headerSlot(db, c, session),
          Expanded(
            flex: 5,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _camera(),
                if (!ready && !_loading)
                  ColoredBox(
                    color: const Color(0xF2F6F8F7),
                    child: _NoticeBody(
                      message: _notice ?? 'لا توجد جلسة مسح لهذا الصف.',
                      onPickClass: _options.isEmpty ? null : _pickClass,
                      onRetry: () => unawaited(_start(widget.classRef)),
                      onAddClass: _options.isEmpty
                          ? () => context.pushNamed(AppRoutes.classes)
                          : null,
                    ),
                  ),
                if (ready && closedAt != null)
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
          Expanded(flex: 3, child: _resultsPanel()),
          SafeArea(child: _bottomButtons(session)),
        ],
      ),
    );
  }

  /// شريط أعلى المعاينة: مؤشر تحميل أثناء فتح الجلسة، ثم تاريخ اليوم وعدّاد
  /// الحضور. (دالة منفصلة لأن ترقية `c`/`session` تحتاج فحصاً صريحاً.)
  Widget _headerSlot(AppDb db, ClassRef? c, Session? session) {
    if (_loading) {
      return const LinearProgressIndicator(minHeight: 3);
    }
    if (c == null || session == null) {
      return const SizedBox.shrink();
    }
    return _Header(session: session, classId: c.id, db: db);
  }

  /// زر الفلاش يعكس حالة المصباح الحقيقية (يعمل/مطفأ/غير مدعوم).
  Widget _torchButton() {
    final MobileScannerController? controller = _controller;
    if (controller == null) {
      return IconButton(
        tooltip: 'الفلاش (الكاميرا غير مهيّأة)',
        icon: const Icon(Icons.flash_off),
        onPressed: () => unawaited(_resetCamera()),
      );
    }
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: controller,
      builder: (BuildContext context, MobileScannerState value, Widget? child) {
        final bool on = value.torchState == TorchState.on;
        return IconButton(
          tooltip: on ? 'إطفاء الفلاش' : 'تشغيل الفلاش',
          icon: Icon(on ? Icons.flash_on : Icons.flash_off),
          color: on ? Colors.amber.shade300 : null,
          onPressed: () => unawaited(_toggleTorch()),
        );
      },
    );
  }

  Widget _camera() {
    final MobileScannerController? controller = _controller;
    if (controller == null) {
      return _NoticeBody(
        message: 'تعذر تهيئة الكاميرا: ${_cameraError ?? 'سبب غير معروف'}',
        onRetry: () => unawaited(_resetCamera()),
      );
    }
    return MobileScanner(
      // مفتاح بهوية المتحكم: عند إعادة التهيئة يُبنى ودجت جديد بدل أن يحتفظ
      // `mobile_scanner` بمتحكم مُتلف داخل حالته (`late final`).
      key: ObjectKey(controller),
      controller: controller,
      onDetect: _onDetect,
      placeholderBuilder: (BuildContext context, Widget? child) =>
          _CameraWaiting(message: _cameraError),
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
        return _NoticeBody(
          message: _cameraMessage(error),
          onRetry: () => unawaited(_resetCamera()),
        );
      },
    );
  }

  /// لوحة النتائج أسفل المعاينة.
  Widget _resultsPanel() {
    if (_feed.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'امسح باج الطالب — ستظهر النتائج هنا فوراً',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _feed.length,
      itemBuilder: (BuildContext context, int i) {
        final ScanOutcome o = _feed[i];
        // التأخر نجاحٌ لكنه يتميز بلون وأيقونة خاصة — رسالته تحمل الوقت.
        final bool late = o.result == ScanResult.late;
        return ListTile(
          dense: true,
          leading: Icon(
            late
                ? Icons.hourglass_bottom
                : (o.isSuccess ? Icons.check_circle : Icons.error),
            color: late
                ? Colors.orange
                : (o.isSuccess ? Colors.green : Colors.red),
          ),
          title: Text(o.message),
        );
      },
    );
  }

  Widget _bottomButtons(Session? session) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            FilledButton.icon(
              onPressed: session == null ? null : _manual,
              icon: const Icon(Icons.edit),
              label: const Text('يدوي'),
            ),
            FilledButton.icon(
              onPressed: session == null ? null : _toggleClose,
              icon: Icon(
                session?.closedAt == null ? Icons.lock : Icons.lock_open,
              ),
              label: Text(
                session?.closedAt == null ? 'إقفال اليوم' : 'إعادة فتح',
              ),
            ),
          ],
        ),
      );
}

/// طبقة الانتظار فوق المعاينة: لا مربع أسود صامت قبل اكتمال تهيئة الكاميرا.
class _CameraWaiting extends StatelessWidget {
  const _CameraWaiting({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFF101413),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  message ?? 'جارٍ تشغيل الكاميرا…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
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
