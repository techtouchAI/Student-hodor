/// معاينة وطباعة بادجات صف كامل (ورقة A4) أو باج مفرد (CR80).
///
/// ثلاث حمايات جوهرية ضد «الشاشة البيضاء»:
/// 1. فشل تحميل الخط لم يعد يُسقط الشاشة (يُعرض تحذير وتبقى المعاينة تعمل)،
///    وأزرار الطباعة (ورقة A4/بطاقة مفردة) لا تعمل قبل جهوزيته.
/// 2. كل طالب يُجهَّز داخل `try/catch`، وصورة المحتوى التالف تُستبدل
///    بمربع الحرف الأول — فلا شيء في طالب واحد يُسقط ورقة البادجات.
/// 3. الصف يُحلّ من قاعدة البيانات ([AppDb.resolveClassRef]) فلا تعتمد الشاشة
///    على سلامة معاملة الرابط.
library;

import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/error_guard.dart';
import '../../core/nav.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../state/providers.dart';
import 'badge_print.dart';
import 'badge_spec.dart';
import 'badge_widget.dart';

class BadgesScreen extends ConsumerStatefulWidget {
  const BadgesScreen({super.key, required this.classRef});

  final ClassRef classRef;

  @override
  ConsumerState<BadgesScreen> createState() => _BadgesState();
}

class _BadgesState extends ConsumerState<BadgesScreen> {
  pw.Font? _fontRegular;
  pw.Font? _fontBold;
  String? _fontsWarning;
  ClassRef? _class;
  Future<List<BadgeSpec>>? _specsFuture;
  List<SchoolClass> _options = <SchoolClass>[];
  String? _resolveError;

  /// أزرار الطباعة لا تعمل قبل تحميل الخطين معاً.
  bool get _fontsReady => _fontRegular != null && _fontBold != null;

  @override
  void initState() {
    super.initState();
    _loadFonts();
    _resolveAndLoad();
  }

  @override
  void didUpdateWidget(BadgesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.classRef.id != widget.classRef.id) {
      _resolveAndLoad();
    }
  }

  Future<void> _resolveAndLoad() async {
    try {
      final AppDb db = ref.read(dbProvider);
      final (int count, ClassRef? resolved) =
          await db.resolveClassRef(widget.classRef);
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
          _specsFuture = Future<List<BadgeSpec>>.value(<BadgeSpec>[]);
          _resolveError = count == 0
              ? 'لا توجد صفوف في السنة الفعّالة — أضف صفاً من شاشة الصفوف.'
              : null;
        });
        return;
      }
      setState(() {
        _class = resolved;
        _resolveError = null;
        _specsFuture = _specs(db, resolved.id);
      });
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'badges:resolve');
      if (mounted) {
        setState(() {
          _class = null;
          _resolveError = '$e';
          _specsFuture = Future<List<BadgeSpec>>.value(<BadgeSpec>[]);
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

  Future<void> _loadFonts() async {
    try {
      final pw.Font regular =
          pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Regular.ttf'));
      final pw.Font bold =
          pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Bold.ttf'));
      if (mounted) {
        setState(() {
          _fontRegular = regular;
          _fontBold = bold;
          _fontsWarning = null;
        });
      }
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'badges:fonts');
      if (mounted) {
        // لا نُسقط الشاشة: المعاينة على الشاشة لا تحتاج خط PDF.
        setState(() => _fontsWarning = 'تعذر تحميل خط الطباعة: $e');
      }
    }
  }

  Future<List<BadgeSpec>> _specs(AppDb db, int classId) async {
    final AcademicYear? year = await db.activeYear();
    final Map<String, String> settings = await db.effectiveSettings();
    if (year == null) {
      return <BadgeSpec>[];
    }
    final List<Student> students = await (db.select(db.students)
          ..where((s) => s.classId.equals(classId))
          ..orderBy(<OrderClauseGenerator<Students>>[
            (Students s) => OrderingTerm.asc(s.fullName),
          ]))
        .get();
    final SchoolClass? c = await (db.select(db.schoolClasses)
          ..where((x) => x.id.equals(classId)))
        .getSingleOrNull();
    final List<BadgeSpec> out = <BadgeSpec>[];
    for (final Student s in students) {
      try {
        final Badge? b = await db.activeBadgeOf(s.id);
        if (b == null) {
          continue;
        }
        List<int>? photo;
        final String? photoPath = s.photoPath;
        if (photoPath != null && photoPath.isNotEmpty) {
          final File f = File(photoPath);
          if (f.existsSync()) {
            final List<int> bytes = await f.readAsBytes();
            photo = await BadgeSpec.validPhotoBytes(bytes);
            if (photo == null) {
              // محتوى تالف: يُسجَّل ويُستبدل بمربع الحرف الأول بدل إسقاط الورقة.
              AppErrorLog.instance.record(
                StateError('صورة تالفة أُسقطت من الباج: $photoPath'),
                StackTrace.current,
                where: 'badges:photo',
              );
            }
          }
        }
        out.add(
          BadgeSpec(
            schoolName: settings['school_name'] ?? '',
            directorName: settings['director_name'] ?? '',
            studentName: s.fullName,
            grade: c?.grade ?? '',
            section: c?.section ?? '',
            yearName: year.name,
            code: b.code,
            sequence: s.seq,
            photoBytes: photo,
            phone: s.phone,
          ),
        );
      } catch (e, st) {
        // طالب واحد تالف (صورة/باج) لا يجوز أن يُسقط ورقة البادجات كلها.
        AppErrorLog.instance.record(e, st, where: 'badges:spec:${s.fullName}');
      }
    }
    return out;
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _printSheet() async {
    final ClassRef? c = _class;
    if (c == null) {
      _snack('اختر صفاً أولاً');
      return;
    }
    final pw.Font? regular = _fontRegular;
    final pw.Font? bold = _fontBold;
    if (regular == null || bold == null) {
      _snack('خط الطباعة غير جاهز بعد — أعد المحاولة');
      return;
    }
    try {
      final List<BadgeSpec> specs = await _specs(ref.read(dbProvider), c.id);
      if (specs.isEmpty) {
        _snack('لا بادجات جاهزة للطباعة في هذا الصف');
        return;
      }
      await BadgePrint.layout(
        BadgePrint.sheet(specs, font: regular, fontBold: bold),
        PdfPageFormat.a4.landscape,
      );
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'badges:printSheet');
      _snack('تعذرت الطباعة: $e');
    }
  }

  Future<void> _printSingle(BadgeSpec spec) async {
    final pw.Font? regular = _fontRegular;
    final pw.Font? bold = _fontBold;
    if (regular == null || bold == null) {
      _snack('خط الطباعة غير جاهز بعد — أعد المحاولة');
      return;
    }
    try {
      await BadgePrint.layout(
        BadgePrint.single(spec, font: regular, fontBold: bold),
        PdfPageFormat(BadgeMetrics.widthPt, BadgeMetrics.heightPt),
      );
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'badges:printSingle');
      _snack('تعذرت طباعة الباج: $e');
    }
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
      await _resolveAndLoadWith(ClassRef(id: c.id, title: '${c.grade} ـ ${c.section}'));
    }
  }

  Future<void> _resolveAndLoadWith(ClassRef requested) async {
    try {
      final AppDb db = ref.read(dbProvider);
      final (_, ClassRef? resolved) = await db.resolveClassRef(requested);
      if (!mounted || resolved == null) {
        return;
      }
      setState(() {
        _class = resolved;
        _resolveError = null;
        _specsFuture = _specs(db, resolved.id);
      });
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'badges:pick');
      _snack('تعذر فتح الصف: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ClassRef? c = _class;
    return Scaffold(
      appBar: AppBar(
        title: Text(c == null ? 'البادجات' : 'بادجات ${c.displayTitle}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _resolveAndLoad,
          ),
          IconButton(
            tooltip: 'طباعة ورقة A4',
            icon: const Icon(Icons.print),
            onPressed: _fontsReady && c != null ? _printSheet : null,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_fontsWarning != null)
            MaterialBanner(
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              content: Text(_fontsWarning!),
              actions: <Widget>[
                TextButton(
                  onPressed: _loadFonts,
                  child: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          Expanded(child: _body(c)),
        ],
      ),
    );
  }

  Widget _body(ClassRef? c) {
    final String? err = _resolveError;
    if (err != null) {
      return Center(
        child: LoadErrorCard(message: err, onRetry: _resolveAndLoad),
      );
    }
    if (c == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.badge_outlined, size: 48),
              const SizedBox(height: 8),
              const Text('لم يُحدَّد صف لهذه الشاشة.', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              if (_options.isNotEmpty)
                FilledButton.icon(
                  onPressed: _pickClass,
                  icon: const Icon(Icons.class_),
                  label: const Text('اختر صفاً'),
                )
              else
                FilledButton.icon(
                  onPressed: () => context.pushNamed(AppRoutes.classes),
                  icon: const Icon(Icons.add),
                  label: const Text('إضافة صف'),
                ),
            ],
          ),
        ),
      );
    }
    return FutureBuilder<List<BadgeSpec>>(
      future: _specsFuture,
      builder: (BuildContext context, AsyncSnapshot<List<BadgeSpec>> snap) {
        if (snap.hasError) {
          AppErrorLog.instance.record(
            snap.error!,
            snap.stackTrace ?? StackTrace.current,
            where: 'badges:specs',
          );
          return Center(
            child: LoadErrorCard(
              message: '${snap.error}',
              onRetry: _resolveAndLoad,
            ),
          );
        }
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final List<BadgeSpec> specs = snap.data ?? <BadgeSpec>[];
        if (specs.isEmpty) {
          return const Center(
            child: Text('لا بادجات في هذا الصف بعد — أضف طلاباً أولاً'),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 300,
            childAspectRatio: 0.63,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: specs.length,
          itemBuilder: (BuildContext context, int i) {
            final BadgeSpec spec = specs[i];
            return InkWell(
              onTap: () => _preview(spec),
              onLongPress: () => _printSingle(spec),
              child: BadgeWidget(spec: spec),
            );
          },
        );
      },
    );
  }

  Future<void> _preview(BadgeSpec spec) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                BadgeWidget(spec: spec, width: 320),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _printSingle(spec);
                  },
                  icon: const Icon(Icons.print),
                  label: const Text('طباعة بطاقة مفردة'),
                ),
                const SizedBox(height: 6),
                const Text('اضغط مطولاً على أي باج للطباعة المباشرة'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
