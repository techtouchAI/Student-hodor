/// اختبارات واجهة للشاشات التي كانت تظهر «بيضاء» في الميدان:
/// الطلاب، البادجات، كشف اليوم (+ الصفوف كنقطة انطلاق).
///
/// كل اختبار يبني الشاشة الحقيقية داخل الراوتر الحقيقي مع قاعدة بيانات في
/// الذاكرة، ثم يتحقق أنها **رسمت طلاب الصف فعلاً** ولم ترمِ أي استثناء.
/// هذا هو الفحص الذي كان غائباً فسمح للعطل بالوصول إلى المستخدم.
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:student_hodor/app.dart';
import 'package:student_hodor/core/error_guard.dart';
import 'package:student_hodor/core/nav.dart';
import 'package:student_hodor/core/school_time.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/state/providers.dart';

Future<AppDb> _seedDb() async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await db.setSetting('school_name', 'مدرسة النجاح');
  await db.setSetting('director_name', 'الأستاذ كريم');
  final int yearId = await db.into(db.academicYears).insert(
        const AcademicYearsCompanion(
          name: Value('2026-2027'),
          start: Value('2026-09-01'),
          end: Value('2027-06-30'),
          active: Value(true),
        ),
      );
  final int classId = await db.into(db.schoolClasses).insert(
        SchoolClassesCompanion(
          yearId: Value(yearId),
          grade: const Value('السادس'),
          section: const Value('أ'),
        ),
      );
  await db.addStudent(yearId: yearId, classId: classId, fullName: 'علي حسن');
  await db.addStudent(yearId: yearId, classId: classId, fullName: 'زيد كريم');
  return db;
}

/// تسوية **محدودة** بإطار زمني: `pumpAndSettle` غير المقيّد قد يدور بلا نهاية
/// إن بقي مؤشر تحميل متحركاً، فيعلّق مجموعة الاختبارات كلها بدل أن يفشل سريعاً.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}


Future<GoRouter> _pumpScreen(
  WidgetTester tester,
  AppDb db,
  String location,
) async {
  final GoRouter router = buildRouter();
  router.go(location);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[dbProvider.overrideWithValue(db)],
      child: StudentHodorApp(router: router),
    ),
  );
  await _settle(tester);
  return router;
}

void main() {
  installErrorGuards();

  group('شاشات الصفوف تُبنى وتعرض بياناتها', () {
    testWidgets('الصفوف: قائمة الصفوف تظهر', (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      await _pumpScreen(tester, db, '/classes');
      expect(find.text('الصفوف والشعب'), findsOneWidget);
      expect(find.text('السادس ـ أ'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets('الصفوف → الطلاب: ضغط الصف يفتح شاشة فيها الطلاب',
        (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      await _pumpScreen(tester, db, '/classes');
      await tester.tap(find.text('السادس ـ أ').first);
      await _settle(tester);
      expect(find.textContaining('طلاب السادس ـ أ'), findsOneWidget);
      expect(find.text('علي حسن'), findsOneWidget);
      expect(find.text('زيد كريم'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets('الطلاب: رابط مباشر بمعامِلات عربية مرمّزة',
        (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      await _pumpScreen(
        tester,
        db,
        AppRoutes.classLocation('/students', 1, 'السادس ـ أ'),
      );
      expect(find.text('علي حسن'), findsOneWidget);
      expect(find.text('زيد كريم'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets('البادجات: الشاشة تُحمِّل باجات الصف بلا عطل',
        (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      await _pumpScreen(
        tester,
        db,
        AppRoutes.classLocation('/badges', 1, 'السادس ـ أ'),
      );
      expect(find.textContaining('بادجات السادس ـ أ'), findsOneWidget);
      expect(find.text('علي حسن'), findsOneWidget);
      expect(find.textContaining('مدرسة النجاح'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets('كشف اليوم: قائمة الحالات + شريط الملخّص',
        (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      final String today = SchoolTime.dateKey(DateTime.now());
      await _pumpScreen(
        tester,
        db,
        AppRoutes.classLocation('/day-sheet', 1, 'السادس ـ أ', date: today),
      );
      expect(find.textContaining('كشف السادس ـ أ'), findsOneWidget);
      expect(find.text('علي حسن'), findsOneWidget);
      expect(find.textContaining('مسجل: 0 / 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('معامِلات تالفة أو مفقودة لا تُنتج صفحة بيضاء', () {
    testWidgets('معرّف صف محذوف ⇒ يُعتمد الصف الوحيد ولا استثناء',
        (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      await _pumpScreen(
        tester,
        db,
        AppRoutes.classLocation('/students', 999, 'صف محذوف'),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('علي حسن'), findsOneWidget);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets('بلا معامِلات إطلاقاً ⇒ الشاشة تُحلّ صفّها من القاعدة',
        (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      await _pumpScreen(tester, db, '/students');
      expect(tester.takeException(), isNull);
      expect(find.text('علي حسن'), findsOneWidget);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets('قيمة class غير رقمية ⇒ لا انهيار',
        (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      await _pumpScreen(tester, db, '/students?class=abc&title=%D8%A7');
      expect(tester.takeException(), isNull);
      expect(find.text('علي حسن'), findsOneWidget);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets('كشف اليوم بلا تاريخ ⇒ يُعتمد اليوم',
        (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      await _pumpScreen(tester, db, '/day-sheet?class=1');
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining(SchoolTime.dateKey(DateTime.now())),
        findsOneWidget,
      );
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets('بلا سنة فعّالة ⇒ رسالة إرشادية لا بياض',
        (WidgetTester tester) async {
      final AppDb db = AppDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await _pumpScreen(tester, db, '/students?class=1');
      expect(tester.takeException(), isNull);
      expect(find.textContaining('لا توجد صفوف'), findsOneWidget);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('extra يتجاوز معاملة الرابط', () {
    testWidgets('ClassRef عبر extra يحدّد الصف والعنوان',
        (WidgetTester tester) async {
      final AppDb db = await _seedDb();
      addTearDown(db.close);
      final GoRouter router = await _pumpScreen(tester, db, '/classes');
      unawaited(
        router.push<void>(
          '/students',
          extra: const ClassRef(id: 1, title: 'السادس ـ أ'),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('طلاب السادس ـ أ'), findsOneWidget);
      expect(find.text('علي حسن'), findsOneWidget);
    },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
