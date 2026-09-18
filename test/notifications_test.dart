/// خدمة التنبيهات: نفس مصدر التقارير (الإنذار المبكر)، الإنشاء مرة واحدة،
/// القدرة على التكرار (idempotency)، تحديث الإحصاء، وسم القراءة، الحذف
/// المتسلسل مع الطالب، وتحليل الحمولة (payload).
///
/// في اختبارات الوحدة لا توجد طبقة منصة ⇒ طبقة النظام «غير جاهزة» ⇒ لا
/// إشعارات نظام، وتبقى السطور معلّقة (`systemShown = false`) — وهذا
/// السلوك المقصود لإعادة المحاولة في الميدان.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/notifications_service.dart';

/// سنة فعّالة وصف وطلبة بثلاثة أنماط:
/// - «كثير الغياب»: 15 غياباً (بلوغ الحد الثاني 15).
/// - «وسط»: 10 غيابات (بين العتبتين).
/// - «يوم واحد»: غياب واحد.
Future<(AppDb, AcademicYear, int, int, int, int)> _seed() async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await db.setSetting('alert_threshold_1', '10');
  await db.setSetting('alert_threshold_2', '15');
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
  Future<int> student(String name, List<int> statuses) async {
    final int id = await db.addStudent(
      yearId: year,
      classId: cls,
      fullName: name,
    );
    for (int i = 0; i < statuses.length; i++) {
      await db.upsertAttendance(
        yearId: year,
        classId: cls,
        studentId: id,
        date: '2026-09-${(i + 1).toString().padLeft(2, '0')}',
        status: statuses[i],
        source: AttendanceSource.manual,
      );
    }
    return id;
  }

  final int heavy = await student(
    'كثير الغياب',
    <int>[
      ...List<int>.filled(15, AttendanceStatus.absent),
      ...List<int>.filled(5, AttendanceStatus.present),
    ],
  );
  final int middle = await student(
    'وسط',
    <int>[
      ...List<int>.filled(10, AttendanceStatus.absent),
      ...List<int>.filled(10, AttendanceStatus.present),
    ],
  );
  final int light = await student('يوم واحد', <int>[AttendanceStatus.absent]);
  final AcademicYear yearRow = (await db.activeYear())!;
  return (db, yearRow, cls, heavy, middle, light);
}

void main() {
  test('بلوغ الحد الثاني يولّد تنبيهاً واحداً والاحتساب المتكرر لا يُكرر',
      () async {
    final (
      AppDb db,
      AcademicYear year,
      int _classId,
      int heavy,
      int middle,
      int light,
    ) = await _seed();
    addTearDown(db.close);

    final NotificationsService svc = NotificationsService(db);
    expect(await svc.sync(), isNotEmpty);
    expect(await svc.sync(), isNotEmpty); // مكرر: القائمة نفسها بلا إنشاء.

    final AlertNotification? n =
        await db.alertOf(year.id, heavy, AlertKinds.threshold2);
    expect(n, isNotNull);
    expect(n!.absentDays, 15);
    expect(n.recordedDays, 20);
    expect(n.thresholdDays, 15.0);
    expect(n.read, isFalse);
    expect(n.occurredAt, isNotNull);
    // بلا طبقة منصة ⇒ لم يُعرض للنظام (يُعاد في الميدان).
    expect(n.systemShown, isFalse);

    // من تحت العتبة لا يُنبّه.
    expect(
      await db.alertOf(year.id, middle, AlertKinds.threshold2),
      isNull,
    );
    expect(
      await db.alertOf(year.id, light, AlertKinds.threshold2),
      isNull,
    );

    // الاحتساب يعيد معرّفات السنة الحالية (لإدارة إشعارات النظام).
    final Set<int> ids = await svc.sync();
    expect(ids, <int>{n.id});
  });

  test('خفض العتبة في الإعدادات يُدخل من لم يكن على القائمة', () async {
    final (
      AppDb db,
      AcademicYear year,
      int _classId,
      int _heavy,
      int middle,
      int light,
    ) = await _seed();
    addTearDown(db.close);

    final NotificationsService svc = NotificationsService(db);
    await svc.sync();
    await db.setSetting('alert_threshold_2', '8');
    await svc.sync();

    final AlertNotification? m =
        await db.alertOf(year.id, middle, AlertKinds.threshold2);
    expect(m, isNotNull);
    expect(m!.absentDays, 10);
    expect(m.thresholdDays, 8.0);
    // «يوم واحد» (1 < 8) ما زال خارج القائمة.
    expect(
      await db.alertOf(year.id, light, AlertKinds.threshold2),
      isNull,
    );
  });

  test('ازدياد الغياب يحدّث الإحصاء بلا تنبيه جديد', () async {
    final (
      AppDb db,
      AcademicYear year,
      int classId,
      int heavy,
      int _middle,
      int _light,
    ) = await _seed();
    addTearDown(db.close);

    final NotificationsService svc = NotificationsService(db);
    await svc.sync();
    // يوم غياب آخر (رابع تسجيل خارج شتنبر).
    await db.upsertAttendance(
      yearId: year.id,
      classId: classId,
      studentId: heavy,
      date: '2026-10-01',
      status: AttendanceStatus.absent,
      source: AttendanceSource.manual,
    );
    await svc.sync();

    final AlertNotification? n =
        await db.alertOf(year.id, heavy, AlertKinds.threshold2);
    expect(n!.absentDays, 16);
    expect(n.recordedDays, 21);
    // تنبيه واحد فقط في السنة.
    final List<AlertNotification> all = await db.alertsOfYear(year.id);
    expect(all.length, 1);
  });

  test('من انخفض تحت العتبة يحتفظ بتنبيهه (سجل تاريخي)', () async {
    final (
      AppDb db,
      AcademicYear year,
      int classId,
      int heavy,
      int _middle,
      int _light,
    ) = await _seed();
    addTearDown(db.close);

    final NotificationsService svc = NotificationsService(db);
    await svc.sync();
    // تصحيح يوم غياب إلى حضور ⇒ 14 < 15.
    await db.upsertAttendance(
      yearId: year.id,
      classId: classId,
      studentId: heavy,
      date: '2026-09-01',
      status: AttendanceStatus.present,
      source: AttendanceSource.manual,
    );
    await svc.sync();

    final AlertNotification? n =
        await db.alertOf(year.id, heavy, AlertKinds.threshold2);
    // التنبيه يبقى (بلغ الحد فعلاً)، وإحصاؤه يتجمد عند آخر حساب وهو على
    // القائمة.
    expect(n, isNotNull);
    expect(n!.absentDays, 15);
    expect(n.recordedDays, 20);
  });

  test('وسم القراءة: فردي وجماعي — ويحرّك عدّاد الجرس', () async {
    final (
      AppDb db,
      AcademicYear year,
      int _classId,
      int _heavy,
      int _middle,
      int _light,
    ) = await _seed();
    addTearDown(db.close);

    final NotificationsService svc = NotificationsService(db);
    await db.setSetting('alert_threshold_2', '8');
    await svc.sync();

    expect(await db.unreadAlertCount(year.id).first, 2);
    final List<AlertNotification> rows = await db.alertsOfYear(year.id);
    await svc.markRead(rows.first.id);
    expect(await db.unreadAlertCount(year.id).first, 1);
    final AlertNotification? marked = rows.first;
    final AlertNotification? after =
        await db.alertOf(year.id, marked.studentId, AlertKinds.threshold2);
    expect(after!.read, isTrue);
    expect(after.readAt, isNotNull);
    await svc.markAllRead(year.id);
    expect(await db.unreadAlertCount(year.id).first, 0);
  });

  test('حذف الطالب يحذف تنبيهه (حذف متسلسل)', () async {
    final (
      AppDb db,
      AcademicYear year,
      int _classId,
      int heavy,
      int _middle,
      int _light,
    ) = await _seed();
    addTearDown(db.close);

    final NotificationsService svc = NotificationsService(db);
    await svc.sync();
    await db.deleteStudent(heavy);
    expect(
      await db.alertOf(year.id, heavy, AlertKinds.threshold2),
      isNull,
    );
    // الاحتساب بعد الحذف لا يولّد تنبيبات (الطالب غادر القائمة والقاعدة).
    expect(await svc.sync(), isEmpty);
  });

  test('بلا سنة فعّالة لا تُحسب تنبيهات', () async {
    final AppDb db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await NotificationsService(db).sync(), isEmpty);
  });

  test('تحليل الحمولة: مسار ووسم، والتالف لا ينفجر', () {
    final Map<String, Object> p = payloadOf(
      notificationId: 7,
      yearId: 1,
      studentId: 123,
    );
    final ({int? notificationId, String? route})? parsed =
        notificationPayloadOf(jsonEncode(p));
    expect(parsed?.notificationId, 7);
    expect(parsed?.route, '/student/123');

    expect(notificationPayloadOf(null), isNull);
    expect(notificationPayloadOf(''), isNull);
    expect(notificationPayloadOf('ليس json'), isNull);
    expect(
      notificationPayloadOf(jsonEncode(<String, Object>{'type': 'x'})),
      isNull,
    );
    final ({int? notificationId, String? route})? noStudent =
        notificationPayloadOf(jsonEncode(<String, Object>{'type': 'student'}));
    expect(noStudent?.route, isNull);
    expect(noStudent?.notificationId, isNull);
  });

  test('تسوية أيام العتبة نصياً', () {
    expect(NotificationsService.formatDays(15.0), '15');
    expect(NotificationsService.formatDays(7.5), '7.5');
  });
}
