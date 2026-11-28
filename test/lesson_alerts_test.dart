import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/lesson_alerts.dart';
import 'package:student_hodor/data/db.dart';

/// اختبارات تنبيهات بداية/نهاية الحصة: التنبيه مرة واحدة لكل (تاريخ، حصة،
/// لحظة)، التبديل بالإعدادات، تنظيف القيم القديمة، تخطي الأوقات التالفة،
/// والكتم في يوم العطلة.
///
/// طبقة النظام ([LocalNotifications]) غير جاهزة في اختبارات الوحدة — ما
/// يُختبر هنا هو تحديد اللحظات الواجب التنبيه عنها، تسجيل الحالة (لا تكرار)،
/// والتحكم بالإعدادات، لا عرض الإشعار نفسه.
void main() {
  late AppDb db;

  setUp(() async {
    db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
  });

  /// سنة فعّالة + صف — الحصص الافتراضية (6 حصص) تُزرع تلقائياً.
  Future<void> seed() async {
    final int year = await db.into(db.academicYears).insert(
          AcademicYearsCompanion(
            name: Value('2026-2027'),
            start: const Value('2026-09-01'),
            end: const Value('2027-06-30'),
            active: Value(true),
          ),
        );
    await db.into(db.schoolClasses).insert(
      SchoolClassesCompanion(
        yearId: Value(year),
        grade: const Value('السادس'),
        section: const Value('أ'),
      ),
    );
  }

  test('تنبيه يحدد اللحظات الواجب التنبيه عنها ويسجل الحالة (لا تكرار)',
      () async {
    await seed();
    final LessonAlerts alerts = LessonAlerts(db);

    // 2026-09-16 أربعاء (يوم دوام): بعد بداية الحصة الأولى (08:00).
    final DateTime now = DateTime(2026, 9, 16, 8, 10);
    await alerts.sync(now: now);

    final String? shown = await db.setting('lesson_alerts_shown');
    expect(shown, contains('2026-09-16:1:start'),
        reason: 'بداية الحصة الأولى تأخر موعدها — تُسجّل',);
    expect(shown, isNot(contains('2026-09-16:1:end')),
        reason: 'نهاية الحصة لم تحن بعد',);
    expect(shown, isNot(contains('2026-09-16:2:start')),
        reason: 'بداية الحصة الثانية لم تحن بعد',);

    // الدورة التالية لا تُعيد التنبيه عن نفس اللحظة.
    await alerts.sync(now: DateTime(2026, 9, 16, 8, 30));
    final String? shown2 = await db.setting('lesson_alerts_shown');
    expect(shown2!.split(',').where((String e) => e.contains(':start')).length,
        1,
        reason: 'لا تكرار لتنبيه البداية',);
  });

  test('تنبيه النهاية يُسجّل عند بلوغ موعدها', () async {
    await seed();
    final LessonAlerts alerts = LessonAlerts(db);

    // بعد نهاية الحصة الأولى (08:45) وبداية الثانية (08:50).
    await alerts.sync(now: DateTime(2026, 9, 16, 8, 50));

    final String? shown = await db.setting('lesson_alerts_shown');
    expect(shown, contains('2026-09-16:1:end'));
    expect(shown, contains('2026-09-16:2:start'));
  });

  test('تعطيل التنبيهات يكتم كل شيء ولا يمسّ الحالة', () async {
    await seed();
    await db.setSetting('lesson_alerts_enabled', '0');
    final LessonAlerts alerts = LessonAlerts(db);

    final int fired = await alerts.sync(now: DateTime(2026, 9, 16, 12, 0));

    expect(fired, 0);
    expect(await db.setting('lesson_alerts_shown'), isNull,
        reason: 'لا تُسجّل حالة تنبيه مع التعطيل',);
  });

  test('قيم «تم التنبيه» القديمة تُنظَّف في كل دورة', () async {
    await seed();
    await db.setSetting(
      'lesson_alerts_shown',
      '2026-09-15:1:start,2026-09-16:1:start',
    );
    final LessonAlerts alerts = LessonAlerts(db);

    await alerts.sync(now: DateTime(2026, 9, 16, 8, 10));

    final String? shown = await db.setting('lesson_alerts_shown');
    expect(shown, isNot(contains('2026-09-15:')),
        reason: 'قيم الأمس تُحذف',);
    expect(shown, contains('2026-09-16:1:start'),
        reason: 'قيم اليوم تُحفظ',);
  });

  test('وقت تالف في الحصة يُتخطى بلا استثناء', () async {
    await seed();
    await (db.update(db.lessons)..where((l) => l.slot.equals(1)))
        .write(LessonsCompanion(end: const Value('xx:xx')));
    final LessonAlerts alerts = LessonAlerts(db);

    // لا استثناء، وبداية الحصة الثانية (08:50) تُسجّل بعد 08:55.
    await alerts.sync(now: DateTime(2026, 9, 16, 8, 55));

    final String? shown = await db.setting('lesson_alerts_shown');
    expect(shown, isNot(contains('2026-09-16:1:')),
        reason: 'الحصة ذات الوقت التالف تُتخطى',);
    expect(shown, contains('2026-09-16:2:start'));
  });

  test('يوم عطلة لا يُنبّه', () async {
    await seed();
    await db.into(db.holidays).insert(
      const HolidaysCompanion(date: Value('2026-09-16'), title: Value('عطلة')),
    );
    final LessonAlerts alerts = LessonAlerts(db);

    final int fired = await alerts.sync(now: DateTime(2026, 9, 16, 12, 0));

    expect(fired, 0);
    expect(await db.setting('lesson_alerts_shown'), isNull);
  });
}
