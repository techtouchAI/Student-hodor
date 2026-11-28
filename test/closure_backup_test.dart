import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/backup_service.dart';
import 'package:student_hodor/data/db.dart';

/// مهمات الإقفال التلقائي في النسخ الاحتياطية: تُحصى، تُدرج في البيان،
/// وتُستعاد كما هي، والنسخ القديمة (بلا القسم) لا تُعطّل الاستعادة.
void main() {
  late AppDb db;

  setUp(() async {
    db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
  });

  Future<({int year, int cls, int lesson})> seed() async {
    final int year = await db.into(db.academicYears).insert(
          const AcademicYearsCompanion(
            name: Value('2026-2027'),
            start: Value('2026-09-01'),
            end: Value('2027-06-30'),
            active: Value(true),
          ),
        );
    final int cls = await db.into(db.schoolClasses).insert(
      SchoolClassesCompanion(
        yearId: Value(year),
        grade: const Value('السادس'),
        section: const Value('أ'),
      ),
    );
    return (year: year, cls: cls, lesson: (await db.firstLesson()).id);
  }

  Future<Map<String, Object?>> manifestOf(Uint8List zip) async {
    final Archive archive = ZipDecoder().decodeBytes(zip);
    final ArchiveFile file = archive.files.firstWhere(
      (ArchiveFile f) => f.name == BackupService.manifestName,
    );
    return jsonDecode(utf8.decode(file.content as List<int>)) as Map<String, Object?>;
  }

  test('البيان يشمل مهمات الإقفال ويُحصيها', () async {
    final s = await seed();
    await db.upsertClosureTask(
      yearId: s.year,
      classId: s.cls,
      date: '2026-09-16',
      lessonId: s.lesson,
      targetAt: '2026-09-16T08:45:00',
    );

    final Uint8List zip = await BackupService(db).exportBytes();
    final BackupInfo info = await BackupService(db).inspect(zip);
    expect(info.counts['closure_tasks'], 1);

    final Map<String, Object?> manifest = await manifestOf(zip);
    expect((manifest['closureTasks'] as List).single['date'], '2026-09-16');
  });

  test('استعادة نسخة جديدة تُعيد مهمات الإقفال كما هي', () async {
    final s = await seed();
    await db.upsertClosureTask(
      yearId: s.year,
      classId: s.cls,
      date: '2026-09-16',
      lessonId: s.lesson,
      targetAt: '2026-09-16T08:45:00',
    );
    final Uint8List zip = await BackupService(db).exportBytes();

    // استعادة في قاعدة فارغة.
    final AppDb restored = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(restored.close);
    await BackupService(restored).restoreFull(zip);

    final List<ClosureTask> tasks =
        await restored.select(restored.closureTasks).get();
    expect(tasks, hasLength(1));
    expect(tasks.single.date, '2026-09-16');
    expect(tasks.single.targetAt, '2026-09-16T08:45:00');
    expect(tasks.single.state, ClosureTaskState.pending);
  });

  test('استعادة بيان قديم (بلا قسم مهمات الإقفال) لا تُعطّل الاستعادة',
      () async {
    final s = await seed();
    await db.upsertClosureTask(
      yearId: s.year,
      classId: s.cls,
      date: '2026-09-16',
      lessonId: s.lesson,
      targetAt: '2026-09-16T08:45:00',
    );
    final Uint8List zip = await BackupService(db).exportBytes();
    final Map<String, Object?> manifest = await manifestOf(zip);

    // بيان كما كان قبل الإصدار 4: بلا `closureTasks`.
    manifest.remove('closureTasks');
    manifest['version'] = 3;
    final Uint8List legacy = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent(' ').convert(manifest)),
    );

    final AppDb restored = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(restored.close);
    await BackupService(restored).restoreFull(legacy);

    expect(await restored.select(restored.closureTasks).get(), isEmpty,
        reason: 'لا مهمات في بيان قديم — تُبنى من الحصص عند التشغيل',);
    expect(await restored.allLessons(), isNotEmpty,
        reason: 'باقي الأقسام تستعاد',);
  });
}
