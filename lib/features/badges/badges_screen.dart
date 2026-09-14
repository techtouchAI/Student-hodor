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

  @override
  void initState() {
    super.initState();
    _loadFonts();
  }

  Future<void> _loadFonts() async {
    final pw.Font regular =
        pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Regular.ttf'));
    final pw.Font bold =
        pw.Font.ttf(await rootBundle.load('assets/fonts/Tajawal-Bold.ttf'));
    BadgePrint.registerFonts(regular, bold);
    if (mounted) {
      setState(() => _fontsReady = true);
    }
  }

  Future<List<BadgeSpec>> _specs(AppDb db) async {
    final AcademicYear? year = await db.activeYear();
    final Map<String, String> settings = await db.allSettings();
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
      final Badge? b = await (db.select(db.badges)
            ..where((x) => x.studentId.equals(s.id) & x.status.equals(0)))
          .getSingleOrNull();
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
    final AppDb db = ref.watch(dbProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('بادجات ${widget.title}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'طباعة ورقة A4',
            icon: const Icon(Icons.print),
            onPressed: _fontsReady ? _printSheet : null,
          ),
        ],
      ),
      body: FutureBuilder<List<BadgeSpec>>(
        future: _specs(db),
        builder: (BuildContext context, AsyncSnapshot<List<BadgeSpec>> snap) {
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
                onLongPress: () => _printSingle(spec),
                child: BadgeWidget(spec: spec),
              );
            },
          );
        },
      ),
    );
  }
}
