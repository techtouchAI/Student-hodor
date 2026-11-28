/// اختبار واجهة: تعديل إجازة محفوظة من شاشة الإجازات — كانت الشاشة تتيح
/// الإضافة والحذف فقط. التعديل يفتح الحوار نفسه بقيم الإجازة ويحفظ في
/// **السطر نفسه** (لا إجازة جديدة) عبر `LeavesService`.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/leaves_service.dart';
import 'package:student_hodor/data/notifications_service.dart';
import 'package:student_hodor/features/leaves/leaves_screen.dart';
import 'package:student_hodor/state/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDb db;
  late int yearId;
  late int studentId;

  setUp(() {
    db = AppDb.forTesting(NativeDatabase.memory());
  });

  /// فصل الشجرة ثم إغلاق القاعدة في التزامن الحقيقي (منهجية اختبارات
  /// الشاشات: اشتراكات drift تُحيل مؤقتًا صفريًا فلا يتبقى مؤقّت معلّق).
  Future<void> tearDownDb(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(db.close);
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// ضخّ إطارات محدود بدل `pumpAndSettle` (رسالة SnackBar قد لا تستقر).
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// سنة فعّالة + طالب بـ16 يوم غياب بلغ حد الفصل + إجازة يوم واحد له
  /// (15 يوماً بعدها: ما زال عند الحد).
  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      await db.setSetting('alert_threshold_2', '15');
      yearId = await db.into(db.academicYears).insert(
            const AcademicYearsCompanion(
              name: Value('2026-2027'),
              start: Value('2026-09-01'),
              end: Value('2027-06-30'),
              active: Value(true),
            ),
          );
      final int cls = await db.into(db.schoolClasses).insert(
            SchoolClassesCompanion(
              yearId: Value(yearId),
              grade: const Value('السادس'),
              section: const Value('أ'),
            ),
          );
      studentId = await db.addStudent(
        yearId: yearId,
        classId: cls,
        fullName: 'علي حسن',
      );
      final int lessonId = (await db.firstLesson()).id;
      for (int d = 1; d <= 16; d++) {
        await db.upsertAttendance(
          yearId: yearId,
          classId: cls,
          studentId: studentId,
          lessonId: lessonId,
          date: '2026-09-${d.toString().padLeft(2, '0')}',
          status: AttendanceStatus.absent,
          source: AttendanceSource.autoClose,
        );
      }
      await NotificationsService(db).sync();
      await LeavesService(db).add(
        yearId: yearId,
        draft: LeaveDraft(
          studentId: studentId,
          start: '2026-09-01',
          end: '2026-09-01',
          type: 0,
          reason: 'زكام',
        ),
      );
    });
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[dbProvider.overrideWithValue(db)],
        child: const MaterialApp(home: LeavesScreen()),
      ),
    );
    await settle(tester);
  }

  Finder field(String label) => find.byWidgetPredicate(
        (Widget w) => w is TextField && w.decoration?.labelText == label,
      );

  testWidgets(
    'زر التعديل يفتح الحوار بقيم الإجازة ويحفظ في السطر نفسه',
    (WidgetTester tester) async {
      await seed(tester);
      try {
        await pumpScreen(tester);
        expect(find.textContaining('زكام'), findsOneWidget);

        await tester.tap(find.byTooltip('تعديل'));
        await settle(tester);

        expect(find.text('تعديل إجازة'), findsOneWidget);
        expect(find.text('2026-09-01'), findsWidgets, reason: 'تاريخ الإجازة');
        final TextField reason = tester.widget<TextField>(
          field('السبب (اختياري)'),
        );
        expect(reason.controller?.text, 'زكام', reason: 'السبب الحالي معبّأ');

        await tester.enterText(field('السبب (اختياري)'), 'مراجعة طبية');
        await tester.tap(find.text('حفظ'));
        await settle(tester);

        expect(tester.takeException(), isNull);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.textContaining('مراجعة طبية'), findsOneWidget);
        expect(find.textContaining('عُدّلت الإجازة'), findsOneWidget);

        late List<Leave> rows;
        await tester.runAsync(() async {
          rows = await db.select(db.leaves).get();
        });
        expect(rows, hasLength(1), reason: 'التعديل لا يُنشئ إجازة جديدة');
        expect(rows.single.reason, 'مراجعة طبية');
        expect(rows.single.studentId, studentId);
        expect(rows.single.start, '2026-09-01');
      } finally {
        await tearDownDb(tester);
      }
    },
  );

  testWidgets(
    'الإلغاء في حوار التعديل لا يغيّر شيئاً',
    (WidgetTester tester) async {
      await seed(tester);
      try {
        await pumpScreen(tester);
        await tester.tap(find.textContaining('زكام'));
        await settle(tester);
        expect(find.text('تعديل إجازة'), findsOneWidget);

        await tester.enterText(field('السبب (اختياري)'), 'لن يُحفظ');
        await tester.tap(find.text('إلغاء'));
        await settle(tester);

        expect(find.byType(AlertDialog), findsNothing);
        late Leave row;
        await tester.runAsync(() async {
          row = await db.select(db.leaves).getSingle();
        });
        expect(row.reason, 'زكام');
      } finally {
        await tearDownDb(tester);
      }
    },
  );

  testWidgets(
    'الإضافة من الحوار نفسه ما زالت تُنشئ إجازة جديدة',
    (WidgetTester tester) async {
      await seed(tester);
      try {
        await pumpScreen(tester);
        await tester.tap(find.byType(FloatingActionButton));
        await settle(tester);
        expect(find.text('إجازة جديدة'), findsOneWidget);
        expect(
          tester.widget<TextField>(field('السبب (اختياري)')).controller?.text,
          isEmpty,
          reason: 'حوار الإضافة يبدأ فارغاً',
        );

        await tester.tap(find.text('حفظ'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(AlertDialog), findsNothing);

        late List<Leave> rows;
        await tester.runAsync(() async {
          rows = await db.select(db.leaves).get();
        });
        expect(rows, hasLength(2), reason: 'الإضافة تُنشئ سطراً جديداً');
        expect(rows.every((Leave l) => l.studentId == studentId), isTrue);
      } finally {
        await tearDownDb(tester);
      }
    },
  );
}
