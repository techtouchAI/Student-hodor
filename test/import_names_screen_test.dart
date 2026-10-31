/// مسار الاستيراد على مستوى الشاشة: المعاينة لا تكتب، والإلغاء لا يضيف،
/// والتأكيد يضيف إلى الصف نفسه بالترتيب — بمنتقٍ محقون بدل منتقي المنصّة.
///
/// الشاشة تُدفع فوق صفحة مضيفة حقيقية (لا `home:` مباشرة) حتى يعمل
/// `Navigator.pop` بعد الاستيراد كما يعمل في التطبيق.
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/features/students/import_names_screen.dart';
import 'package:student_hodor/state/providers.dart';

const Timeout _kTimeout = Timeout(Duration(seconds: 60));

Future<AppDb> _seed(WidgetTester tester) async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await tester.runAsync(() async {
    final int yearId = await db.into(db.academicYears).insert(
          const AcademicYearsCompanion(
            name: Value('2026-2027'),
            start: Value('2026-09-01'),
            end: Value('2027-06-30'),
            active: Value(true),
          ),
        );
    await db.into(db.schoolClasses).insert(
          SchoolClassesCompanion(
            yearId: Value(yearId),
            grade: const Value('السادس'),
            section: const Value('أ'),
          ),
        );
  });
  return db;
}

Future<void> _tearDown(WidgetTester tester, AppDb db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(db.close);
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

NameFilePick _txt(String text) =>
    (name: 'names.txt', bytes: Uint8List.fromList(utf8.encode(text)));

/// صفحة مضيفة تدفع شاشة الاستيراد بالزر — كما تصل إليها من شاشة الطلاب.
class _Host extends StatelessWidget {
  const _Host({required this.picker});

  final NameFilePicker picker;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Builder(
            builder: (BuildContext ctx) => TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => ImportNamesScreen(
                    classId: 1,
                    classTitle: 'السادس ـ أ',
                    picker: picker,
                  ),
                ),
              ),
              child: const Text('افتح الاستيراد'),
            ),
          ),
        ),
      );
}

/// يفتح الشاشة من الصفحة المضيفة ويترك المنتقي المحقون يقرّر الملف.
Future<void> _open(WidgetTester tester, AppDb db, NameFilePicker picker) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[dbProvider.overrideWithValue(db)],
      child: MaterialApp(home: _Host(picker: picker)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('افتح الاستيراد'));
  await tester.pumpAndSettle();
}

Future<void> _pickFile(WidgetTester tester) async {
  await tester.tap(find.text('اختيار ملف'));
  await _settle(tester);
}

Future<int> _countStudents(WidgetTester tester, AppDb db) async {
  int count = 0;
  await tester.runAsync(() async {
    count = (await db.select(db.students).get()).length;
  });
  return count;
}

void main() {
  testWidgets(
    'المعاينة تعرض الأسماء ولا تكتب شيئاً قبل التأكيد',
    (WidgetTester tester) async {
      final AppDb db = await _seed(tester);
      try {
        await _open(tester, db, () async => _txt('أحمد علي\nبشار كريم\n'));
        await _pickFile(tester);

        expect(find.text('المعاينة'), findsOneWidget);
        expect(find.textContaining('أحمد علي'), findsOneWidget);
        expect(find.textContaining('بشار كريم'), findsOneWidget);
        expect(find.text('استيراد 2 اسماً'), findsOneWidget);
        expect(
          await _countStudents(tester, db),
          0,
          reason: 'المعاينة لا تكتب أي صف قبل ضغط الاستيراد',
        );
      } finally {
        await _tearDown(tester, db);
      }
    },
    timeout: _kTimeout,
  );

  testWidgets(
    'إلغاء منتقي الملفات لا يُنتج معاينة ولا يكتب',
    (WidgetTester tester) async {
      final AppDb db = await _seed(tester);
      try {
        await _open(tester, db, () async => null);
        await _pickFile(tester);

        expect(find.text('المعاينة'), findsNothing);
        expect(find.textContaining('اسماً'), findsNothing);
        expect(find.textContaining('تعذر'), findsNothing);
        expect(await _countStudents(tester, db), 0);
      } finally {
        await _tearDown(tester, db);
      }
    },
    timeout: _kTimeout,
  );

  testWidgets(
    'التراجع في نافذة التأكيد بعد المعاينة لا يضيف طلاباً',
    (WidgetTester tester) async {
      final AppDb db = await _seed(tester);
      try {
        await _open(tester, db, () async => _txt('أحمد علي\nبشار كريم\n'));
        await _pickFile(tester);
        await tester.tap(find.text('استيراد 2 اسماً'));
        await _settle(tester);

        expect(find.text('تأكيد الاستيراد'), findsOneWidget);
        await tester.tap(find.text('تراجع'));
        await _settle(tester);

        expect(find.text('تأكيد الاستيراد'), findsNothing);
        expect(
          await _countStudents(tester, db),
          0,
          reason: 'الإلغاء بعد المعاينة لا يكتب شيئاً',
        );
      } finally {
        await _tearDown(tester, db);
      }
    },
    timeout: _kTimeout,
  );

  testWidgets(
    'ملف تالف يعرض رسالة واضحة ولا يُسقط الشاشة ولا يكتب',
    (WidgetTester tester) async {
      final AppDb db = await _seed(tester);
      try {
        await _open(
          tester,
          db,
          () async => (
            name: 'names.docx',
            bytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
          ),
        );
        await _pickFile(tester);

        expect(tester.takeException(), isNull);
        expect(
          find.textContaining('تعذر قراءة مستند Word'),
          findsOneWidget,
          reason: 'رسالة صريحة بدل انهيار أو معاينة فارغة صامتة',
        );
        expect(find.text('المعاينة'), findsNothing);
        expect(find.textContaining('اسماً'), findsNothing);
        expect(await _countStudents(tester, db), 0);
      } finally {
        await _tearDown(tester, db);
      }
    },
    timeout: _kTimeout,
  );

  testWidgets(
    'التأكيد يضيف الأسماء إلى الصف نفسه بالترتيب ويعود للشاشة السابقة',
    (WidgetTester tester) async {
      final AppDb db = await _seed(tester);
      try {
        await _open(
          tester,
          db,
          () async => _txt('أحمد علي\nبشار كريم\nأحمد علي\n'),
        );
        await _pickFile(tester);
        // المكرر داخل الملف أُسقط في المعاينة ⇒ زر الاستيراد لاسمين.
        expect(find.text('استيراد 2 اسماً'), findsOneWidget);

        await tester.tap(find.text('استيراد 2 اسماً'));
        await _settle(tester);
        await tester.tap(find.text('استيراد'));
        await _settle(tester);

        expect(tester.takeException(), isNull);
        expect(
          find.text('افتح الاستيراد'),
          findsOneWidget,
          reason: 'تعود إلى الشاشة السابقة بعد نجاح الاستيراد',
        );

        late List<Student> kids;
        await tester.runAsync(() async {
          kids = await (db.select(db.students)
                ..orderBy(<OrderClauseGenerator<Students>>[
                  (Students s) => OrderingTerm.asc(s.seq),
                ]))
              .get();
        });
        expect(
          <String>[for (final Student s in kids) s.fullName],
          <String>['أحمد علي', 'بشار كريم'],
        );
        expect(<int>[for (final Student s in kids) s.seq], <int>[1, 2]);
        expect(kids.every((Student s) => s.classId == 1), isTrue);
      } finally {
        await _tearDown(tester, db);
      }
    },
    timeout: _kTimeout,
  );
}
