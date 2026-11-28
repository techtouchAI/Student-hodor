import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/features/leaves/leaves_screen.dart';
import 'package:student_hodor/state/providers.dart';

/// اختبار واجهة: بحث الطلاب في حوار «إجازة جديدة» — مع كثرة الطلاب
/// يُمكّن البحث من الوصول للطالب المطلوب دون تصفح قائمة كاملة.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDb db;

  setUp(() async {
    db = AppDb.forTesting(NativeDatabase.memory());
  });

  /// فصل الشجرة ثم إغلاق القاعدة في التزامن الحقيقي (نفس منهجية اختبارات
  /// الشاشات: تُحيل اشتراكات drift مؤقتًا صفريًا فلا يتبقى مؤقّت معلّق).
  Future<void> tearDownDb(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(db.close);
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// سنة فعّالة + صف + ثلاثة طلاب بأسماء متشابهة (نصف اسم مشترك).
  Future<void> seedDb(WidgetTester tester) async {
    await tester.runAsync(() async {
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
      final List<String> names = <String>[
        'أحمد حسن',
        'محمد كريم',
        'علي حسن',
      ];
      for (int i = 0; i < names.length; i++) {
        final String name = names[i];
        await db.into(db.students).insert(
          StudentsCompanion(
            yearId: Value(year),
            classId: Value(cls),
            fullName: Value(name),
            personKey: Value('p-${name.hashCode}'),
            // الترقيم داخل الصف فريد: كل طالب برقم تسلسلي مختلف.
            seq: Value(i),
            createdAt: const Value('2026-09-01T08:00:00'),
          ),
        );
      }
    });
  }

  testWidgets(
    'بحث الطلاب في حوار الإجازة يصفي القائمة حسب الاسم',
    (WidgetTester tester) async {
      await seedDb(tester);
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[dbProvider.overrideWithValue(db)],
            child: const LeavesScreen(),
          ),
        );
        await tester.pumpAndSettle();

        // فتح حوار «إجازة جديدة».
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();

        // كتابة جزء من اسم طالب.
        await tester.enterText(
          find.byWidgetPredicate(
            (Widget w) =>
                w is TextField && w.decoration?.labelText == 'بحث في الطلاب',
          ),
          'محمد',
        );
        await tester.pumpAndSettle();

        // فتح قائمة الطلاب: تُصفى حسب النص المكتوب.
        await tester.tap(
          find.byWidgetPredicate(
            (Widget w) =>
                w is DropdownButtonFormField &&
                w.decoration.labelText == 'الطالب',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('محمد كريم'), findsOneWidget,
            reason: 'الطالب المطابق يظهر',);
        expect(find.text('أحمد حسن'), findsNothing,
            reason: 'الطلاب غير المطابقين لا يظهرون',);
        expect(find.text('علي حسن'), findsNothing);
      } finally {
        await tearDownDb(tester);
      }
    },
  );

  testWidgets(
    'بحث بلا نتيجة يُظهر رسالة ولا ينهار الحوار',
    (WidgetTester tester) async {
      await seedDb(tester);
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[dbProvider.overrideWithValue(db)],
            child: const LeavesScreen(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byWidgetPredicate(
            (Widget w) =>
                w is TextField && w.decoration?.labelText == 'بحث في الطلاب',
          ),
          'لا يوجد طالب بهذا الاسم',
        );
        await tester.pumpAndSettle();

        expect(find.text('لا طالب مطابق للبحث'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tearDownDb(tester);
      }
    },
  );
}
