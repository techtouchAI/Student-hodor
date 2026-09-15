/// معاينة وطباعة بادجات صف كامل (ورقة A4) أو باج مفرد (CR80).
library;

import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/db.dart';
import '../../state/providers.dart';
import 'badge_print.dart';
import 'badge_spec.dart';
import 'badge_widget.dart';

class BadgesScreen extends ConsumerStatefulWidget {
  const BadgesScreen({super.key, required this.classId, required this.title});

  final int classId;
  final String title;

  @override
  ConsumerState<BadgesScreen> createState() => _BadgesState();
}

class _BadgesState extends ConsumerState<BadgesScreen> {
  bool _fontsReady = false;
  String? _fontsError;
  Future<List<BadgeSpec>>? _specsFuture;

  @override
  void initState() {
    super.initState();
    _loadFonts();
    _reload();
  }

  void _reload() {
    setState(() => _specsFuture = _specs(ref.read(dbProvider)));
  }

  Future<void> _loadFonts() async {
    try {
      final pw.Font regular =
          pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Regular.ttf'));
      final pw.Font bold =
          pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Bold.ttf'));
      BadgePrint.registerFonts(regular, bold);
      if (mounted) {
        setState(() => _fontsReady = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _fontsError = '$e');
      }
    }
  }

  Future<List<BadgeSpec>> _specs(AppDb db) async {
    final AcademicYear? year = await db.activeYear();
    final Map<String, String> settings = await db.effectiveSettings();
    if (year == null) {
      return <BadgeSpec>[];
    }
    final List<Student> students = await (db.select(db.students)
          ..where((s) => s.classId.equals(widget.classId))
          ..orderBy(<OrderClauseGenerator<Students>>[
            (Students s) => OrderingTerm.asc(s.fullName),
          ]))
        .get();
    final List<BadgeSpec> out = <BadgeSpec>[];
    for (final Student s in students) {
      final Badge? b = await db.activeBadgeOf(s.id);
      if (b == null) {
        continue;
      }
      List<int>? photo;
      if (s.photoPath != null && File(s.photoPath!).existsSync()) {
        photo = await File(s.photoPath!).readAsBytes();
      }
      final SchoolClass? c = await (db.select(db.schoolClasses)
            ..where((x) => x.id.equals(s.classId)))
          .getSingleOrNull();
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
        ),
      );
    }
    return out;
  }

  Future<void> _printSheet() async {
    final List<BadgeSpec> specs = await _specs(ref.read(dbProvider));
    if (specs.isEmpty || !mounted) {
      return;
    }
    await BadgePrint.layout(BadgePrint.sheet(specs));
  }

  Future<void> _printSingle(BadgeSpec spec) async {
    await BadgePrint.layout(BadgePrint.single(spec));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('بادجات ${widget.title}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
          IconButton(
            tooltip: 'طباعة ورقة A4',
            icon: const Icon(Icons.print),
            onPressed: _fontsReady ? _printSheet : null,
          ),
        ],
      ),
      body: _fontsError != null
          ? Center(child: Text('تعذر تحميل الخط: $_fontsError'))
          : FutureBuilder<List<BadgeSpec>>(
              future: _specsFuture,
              builder: (
                BuildContext context,
                AsyncSnapshot<List<BadgeSpec>> snap,
              ) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final List<BadgeSpec> specs = snap.data ?? <BadgeSpec>[];
                if (specs.isEmpty) {
                  return const Center(child: Text('لا طلاب في هذا الصف بعد'));
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
            ),
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
