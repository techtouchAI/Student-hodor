/// اختبارات واجهة للشاشات التي كانت تظهر «بيضاء» في الميدان:
/// الطلاب، البادجات، كشف اليوم (+ الصفوف كنقطة انطلاق).
///
/// كل اختبار يبني الشاشة الحقيقية داخل الراوتر الحقيقي مع قاعدة بيانات في
/// الذاكرة، ثم يتحقق أنها **رسمت طلاب الصف فعلاً** ولم ترمِ أي استثناء.
/// هذا هو الفحص الذي كان غائباً فسمح للعطل بالوصول إلى المستخدم.
///
/// ملاحظتان أساسيتان في التعامل مع drift داخل `testWidgets`:
///  * البذر والإغلاق يتمّان عبر [WidgetTester.runAsync] (تزامن حقيقي)، لأن
///    استعلامات drift عبر FFI لا تكتمل داخل FakeAsync فتُعلّق الاختبار.
///  * قبل الإغلاق نفصل الشجرة ونمرّر إطاراً: إلغاء اشتراك `StreamBuilder`
///    يجعل drift يجدول مؤقّتاً صفرياً، وإن بقي معلّقاً يفشل الاختبار بـ
///    «A Timer is still pending» حتى لو نجحت كل التأكيدات.
library;

import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show CircularProgressIndicator;
import 'package:flutter/widgets.dart'
    show Size, SizedBox, Text, TextOverflow;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:student_hodor/app.dart';
import 'package:student_hodor/core/error_guard.dart';
import 'package:student_hodor/core/nav.dart';
import 'package:student_hodor/core/school_time.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/state/providers.dart';

/// مهلة لكل اختبار: إن عَلِق شيء نفشل بسرعة بدل تعطيل مجموعة الاختبارات كلها.
const Timeout _kTestTimeout = Timeout(Duration(seconds: 60));

/// قاعدة فارغة (بلا سنة فعّالة) — تُستخدم لاختبار مسار الإرشاد لا البياض.
Future<AppDb> _newDb(WidgetTester tester) async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await tester.runAsync(() async => db.setSetting('school_name', 'مدرسة النجاح'));
  return db;
}

/// قاعدة مبذورة بسنة فعّالة وصف وطالبين.
Future<AppDb> _seedDb(WidgetTester tester) async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await tester.runAsync(() async {
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
  });
  return db;
}

/// إنهاء نظيف: فصل الشجرة (يلغي اشتراكات drift) ثم تصريف المؤقّت الصفري ثم
/// إغلاق القاعدة في التزامن الحقيقي.
Future<void> _tearDownDb(WidgetTester tester, AppDb db) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(db.close);
  await tester.pump(const Duration(milliseconds: 1));
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

/// نافذة اختبار طويلة: `ListView` كسول، فبدون ارتفاع كافٍ لا تُبنى بطاقات
/// أسفل الشاشة ولا يمكن التأكد من ظهورها.
void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  installErrorGuards();

  group('شاشات الصفوف تُبنى وتعرض بياناتها', () {
    testWidgets(
      'الصفوف: قائمة الصفوف تظهر',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(tester, db, '/classes');
          expect(find.text('الصفوف والشعب'), findsOneWidget);
          expect(find.text('السادس ـ أ'), findsWidgets);
          expect(find.textContaining('طلاب: 2'), findsOneWidget);
          expect(find.byTooltip('البادجات'), findsOneWidget);
          expect(find.byTooltip('كشف اليوم'), findsOneWidget);
          expect(find.byTooltip('تعديل'), findsOneWidget);
          expect(find.byTooltip('حذف'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'الصفوف → الطلاب: ضغط الصف يفتح شاشة فيها الطلاب',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(tester, db, '/classes');
          await tester.tap(find.text('السادس ـ أ').first);
          await _settle(tester);
          expect(find.textContaining('طلاب السادس ـ أ'), findsOneWidget);
          expect(find.text('علي حسن'), findsOneWidget);
          expect(find.text('زيد كريم'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'الطلاب: رابط مباشر بمعامِلات عربية مرمّزة',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(
            tester,
            db,
            AppRoutes.classLocation('/students', 1, 'السادس ـ أ'),
          );
          expect(find.text('علي حسن'), findsOneWidget);
          expect(find.text('زيد كريم'), findsOneWidget);
          expect(find.byTooltip('الباج والرمز'), findsWidgets);
          expect(find.byTooltip('ملف الحضور'), findsWidgets);
          expect(find.byTooltip('تعديل'), findsWidgets);
          expect(find.byTooltip('حذف'), findsWidgets);
          expect(tester.takeException(), isNull);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'البادجات: الشاشة تُحمِّل باجات الصف بلا عطل',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(
            tester,
            db,
            AppRoutes.classLocation('/badges', 1, 'السادس ـ أ'),
          );
          expect(find.textContaining('بادجات السادس ـ أ'), findsOneWidget);
          expect(find.text('علي حسن'), findsOneWidget);
          expect(find.textContaining('مدرسة النجاح'), findsWidgets);
          expect(tester.takeException(), isNull);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'كشف اليوم: قائمة الحالات + شريط الملخّص',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
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
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );
  });

  group('معامِلات تالفة أو مفقودة لا تُنتج صفحة بيضاء', () {
    testWidgets(
      'معرّف صف محذوف ⇒ يُعتمد الصف الوحيد ولا استثناء',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(
            tester,
            db,
            AppRoutes.classLocation('/students', 999, 'صف محذوف'),
          );
          expect(tester.takeException(), isNull);
          expect(find.text('علي حسن'), findsOneWidget);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'بلا معامِلات إطلاقاً ⇒ الشاشة تُحلّ صفّها من القاعدة',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(tester, db, '/students');
          expect(tester.takeException(), isNull);
          expect(find.text('علي حسن'), findsOneWidget);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'قيمة class غير رقمية ⇒ لا انهيار',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(tester, db, '/students?class=abc&title=%D8%A7');
          expect(tester.takeException(), isNull);
          expect(find.text('علي حسن'), findsOneWidget);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'كشف اليوم بلا تاريخ ⇒ يُعتمد اليوم',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(tester, db, '/day-sheet?class=1');
          expect(tester.takeException(), isNull);
          expect(
            find.textContaining(SchoolTime.dateKey(DateTime.now())),
            findsOneWidget,
          );
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'بلا سنة فعّالة ⇒ رسالة إرشادية لا بياض',
      (WidgetTester tester) async {
        final AppDb db = await _newDb(tester);
        try {
          await _pumpScreen(tester, db, '/students?class=1');
          expect(tester.takeException(), isNull);
          expect(find.textContaining('لا توجد صفوف'), findsOneWidget);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );
  });

  group('extra يتجاوز معاملة الرابط', () {
    testWidgets(
      'ClassRef عبر extra يحدّد الصف والعنوان',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
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
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );
  });

  group('بطاقات الصفوف والطلاب: لا نص مقتطع', () {
    testWidgets(
      'بطاقة الصف: الاسم وعدد الطلاب بلا ellipsis وبلا حدّ أسطر',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(tester, db, '/classes');
          final Text count = tester.widget<Text>(
            find.textContaining('طلاب: 2'),
          );
          expect(count.overflow, isNot(TextOverflow.ellipsis));
          expect(count.maxLines, isNull);
          final Text title = tester.widget<Text>(
            find.text('السادس ـ أ').first,
          );
          expect(title.overflow, isNot(TextOverflow.ellipsis));
          expect(title.maxLines, isNull);
          // الأزرار الأربعة ما زالت موجودة (لم تُخفَ لصالح النص).
          expect(find.byTooltip('البادجات'), findsOneWidget);
          expect(find.byTooltip('كشف اليوم'), findsOneWidget);
          expect(find.byTooltip('تعديل'), findsOneWidget);
          expect(find.byTooltip('حذف'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'بطاقة الطالب: رقم الطالب بلا ellipsis',
      (WidgetTester tester) async {
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(
            tester,
            db,
            AppRoutes.classLocation('/students', 1, 'السادس ـ أ'),
          );
          final Text seq = tester.widget<Text>(
            find.textContaining('رقم الطالب:').first,
          );
          expect(seq.overflow, isNot(TextOverflow.ellipsis));
          expect(seq.maxLines, isNull);
          expect(tester.takeException(), isNull);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );
  });

  group('ملف الطالب يُحمَّل فعلاً (لا دوران بلا نهاية)', () {
    testWidgets(
      'ضغط اسم الطالب يعرض ملفه كاملاً',
      (WidgetTester tester) async {
        _useTallWindow(tester);
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(
            tester,
            db,
            AppRoutes.classLocation('/students', 1, 'السادس ـ أ'),
          );
          await tester.tap(find.text('علي حسن').first);
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(find.text('ملف الطالب'), findsOneWidget);
          // هذه هي العلّة المبلّغة: مؤشر تحميل لا يختفي أبداً لأن `StreamBuilder`
          // على تدفق drift لا يصل إلى `ConnectionState.done`.
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(find.text('علي حسن'), findsWidgets);
          expect(find.text('النسبة'), findsOneWidget);
          expect(find.text('مسيرة الطالب عبر السنوات'), findsOneWidget);
          expect(find.text('الإجازات'), findsOneWidget);
          expect(find.byTooltip('الشهر السابق'), findsOneWidget);
          expect(find.byTooltip('الشهر التالي'), findsOneWidget);
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );

    testWidgets(
      'التنقّل بين الأشهر يعيد بناء الشبكة بلا عطل',
      (WidgetTester tester) async {
        _useTallWindow(tester);
        final AppDb db = await _seedDb(tester);
        try {
          await _pumpScreen(
            tester,
            db,
            AppRoutes.classLocation('/students', 1, 'السادس ـ أ'),
          );
          await tester.tap(find.text('علي حسن').first);
          await _settle(tester);
          await tester.tap(find.byTooltip('الشهر السابق'));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          final int previousMonth = DateTime.now().month == 1
              ? 12
              : DateTime.now().month - 1;
          expect(
            find.textContaining(SchoolTime.monthNames[previousMonth - 1]),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('الشهر التالي'));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.textContaining(SchoolTime.monthNames[DateTime.now().month - 1]),
            findsOneWidget,
          );
        } finally {
          await _tearDownDb(tester, db);
        }
      },
      timeout: _kTestTimeout,
    );
  });
}
