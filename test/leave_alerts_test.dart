/// الإجازة وتنبيه حد الفصل (`LeavesService` + `NotificationsService`):
///
/// - إجازة تغطّي أيام الغياب المؤدية للفصل ⇒ يُزال الطالب من التنبيهات فورًا
///   ولا يعود في الاحتساب التالي.
/// - إجازة جزئية تُبقيه عند الحد ⇒ التنبيه باقٍ (وإحصاؤه يتحدّث).
/// - **تعديل** الإجازة (توسيع/تضييق/نقل لطالب آخر) يزامن الحضور ويعيد
///   تقييم التنبيه في الاتجاهين.
/// - الحذف يعيد الغياب، والعودة إلى الحد تولّد تنبيهًا جديدًا.
/// - التحقق في طبقة البيانات والارتداد الذرّي عند الفشل.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/leaves_service.dart';
import 'package:student_hodor/data/notifications_service.dart';

/// مفتاح اليوم رقم [n] (1 = 2026-09-01) — يتخطى نهاية الشهر بأمان.
String _day(int n) {
  final DateTime d = DateTime(2026, 9, n);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

class _Fixture {
  _Fixture(this.db, this.yearId, this.classId);

  final AppDb db;
  final int yearId;
  final int classId;

  late final NotificationsService alerts = NotificationsService(db);
  late final LeavesService leaves = LeavesService(db);

  /// طالب بـ[absentDays] يوم غياب (الأيام 1..N) ثم [presentDays] حضور.
  Future<int> student(
    String name, {
    required int absentDays,
    int presentDays = 0,
  }) async {
    final int id = await db.addStudent(
      yearId: yearId,
      classId: classId,
      fullName: name,
    );
    final int lessonId = (await db.firstLesson()).id;
    for (int i = 1; i <= absentDays + presentDays; i++) {
      await db.upsertAttendance(
        yearId: yearId,
        classId: classId,
        studentId: id,
        lessonId: lessonId,
        date: _day(i),
        status: i <= absentDays
            ? AttendanceStatus.absent
            : AttendanceStatus.present,
        source: AttendanceSource.autoClose,
      );
    }
    return id;
  }

  Future<AlertNotification?> alertOf(int studentId) =>
      db.alertOf(yearId, studentId, AlertKinds.threshold2);

  Future<int?> statusOn(int studentId, int day) async =>
      (await db.attendanceOf(studentId, _day(day), (await db.firstLesson()).id))
          ?.status;

  LeaveDraft draft(int studentId, int fromDay, int toDay) => LeaveDraft(
        studentId: studentId,
        start: _day(fromDay),
        end: _day(toDay),
        type: 0,
      );

  Future<Leave> onlyLeave() => db.select(db.leaves).getSingle();
}

Future<_Fixture> _fixture({String threshold = '15'}) async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  await db.setSetting('alert_threshold_1', '10');
  await db.setSetting('alert_threshold_2', threshold);
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
  return _Fixture(db, year, cls);
}

void main() {
  test('إجازة تغطّي أيام الفصل تزيل الطالب من التنبيهات ولا يعود', () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int heavy = await f.student('كثير الغياب', absentDays: 15, presentDays: 5);
    await f.alerts.sync();
    final AlertNotification? before = await f.alertOf(heavy);
    expect(before, isNotNull, reason: 'بلغ الحد قبل الإجازة');

    final LeaveChange change =
        await f.leaves.add(yearId: f.yearId, draft: f.draft(heavy, 1, 15));

    expect(change.syncedLessons, 15);
    expect(
      <int>[for (final AlertNotification n in change.dismissedAlerts) n.id],
      <int>[before!.id],
    );
    expect(await f.alertOf(heavy), isNull, reason: 'أُزيل فور حفظ الإجازة');
    expect(await f.statusOn(heavy, 1), AttendanceStatus.leave);
    expect(await f.alerts.sync(), isEmpty, reason: 'الاحتساب لا يعيده');
    expect(await f.db.unreadAlertCount(f.yearId).first, 0);

    final List<AuditLog> audit = await (f.db.select(f.db.auditLogs)
          ..where((AuditLogs a) => a.action.equals('alert_dismissed')))
        .get();
    expect(audit, hasLength(1));
  });

  test('إجازة جزئية تُبقي الطالب عند الحد فيبقى تنبيهه', () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int heavy = await f.student('كثير الغياب', absentDays: 17);
    await f.alerts.sync();

    final LeaveChange change =
        await f.leaves.add(yearId: f.yearId, draft: f.draft(heavy, 1, 2));

    expect(change.dismissedAlerts, isEmpty);
    await f.alerts.sync();
    final AlertNotification? n = await f.alertOf(heavy);
    expect(n, isNotNull, reason: '15 يوماً ما زالت عند الحد');
    expect(n!.absentDays, 15);
  });

  test('تعديل الإجازة: التوسيع يزيل التنبيه والتضييق يعيد الغياب والتنبيه',
      () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int heavy = await f.student('كثير الغياب', absentDays: 16);
    await f.alerts.sync();
    final int firstAlertId = (await f.alertOf(heavy))!.id;

    await f.leaves.add(yearId: f.yearId, draft: f.draft(heavy, 1, 1));
    expect(await f.alertOf(heavy), isNotNull, reason: '15 = الحد');

    // توسيع إلى يومين ⇒ 14 < 15 ⇒ يُزال.
    LeaveChange change =
        await f.leaves.update(await f.onlyLeave(), f.draft(heavy, 1, 2));
    expect(change.syncedLessons, 1);
    expect(change.dismissedAlerts, hasLength(1));
    expect(await f.alertOf(heavy), isNull);
    expect(await f.statusOn(heavy, 2), AttendanceStatus.leave);

    // تضييق إلى اليوم الأول ⇒ اليوم الثاني يعود غياباً ⇒ 15 ⇒ تنبيه جديد.
    change = await f.leaves.update(await f.onlyLeave(), f.draft(heavy, 1, 1));
    expect(change.syncedLessons, 1);
    expect(change.dismissedAlerts, isEmpty);
    expect(await f.statusOn(heavy, 1), AttendanceStatus.leave);
    expect(await f.statusOn(heavy, 2), AttendanceStatus.absent);
    await f.alerts.sync();
    final AlertNotification? again = await f.alertOf(heavy);
    expect(again, isNotNull);
    expect(again!.id, isNot(firstAlertId), reason: 'بلوغ جديد = تنبيه جديد');
    expect(again.absentDays, 15);

    // سطر الإجازة واحد دائماً: التعديل لا يُنشئ إجازة جديدة.
    expect(await f.db.select(f.db.leaves).get(), hasLength(1));
  });

  test('تعديل الإجازة يحدّث النوع والسبب والنطاق في السطر نفسه', () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int s = await f.student('طالب', absentDays: 3);
    final LeaveChange added =
        await f.leaves.add(yearId: f.yearId, draft: f.draft(s, 1, 1));

    await f.leaves.update(
      await f.onlyLeave(),
      LeaveDraft(
        studentId: s,
        start: _day(1),
        end: _day(3),
        type: 2,
        fromSlot: 1,
        toSlot: 2,
        reason: '  مراجعة طبية  ',
      ),
    );

    final Leave l = await f.onlyLeave();
    expect(l.id, added.leaveId);
    expect(l.yearId, f.yearId);
    expect(l.end, _day(3));
    expect(l.type, 2);
    expect(l.fromSlot, 1);
    expect(l.toSlot, 2);
    expect(l.reason, 'مراجعة طبية');
    expect(await f.statusOn(s, 3), AttendanceStatus.leave);
  });

  test('نقل الإجازة إلى طالب آخر يعيد غياب الأول ويُسقط تنبيه الثاني',
      () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int heavy = await f.student('كثير الغياب', absentDays: 15);
    final int other = await f.student('آخر', absentDays: 1);
    await f.alerts.sync();
    await f.leaves.add(yearId: f.yearId, draft: f.draft(other, 1, 1));
    expect(await f.statusOn(other, 1), AttendanceStatus.leave);

    final LeaveChange change =
        await f.leaves.update(await f.onlyLeave(), f.draft(heavy, 1, 1));

    expect(await f.statusOn(other, 1), AttendanceStatus.absent);
    expect(await f.statusOn(heavy, 1), AttendanceStatus.leave);
    expect(change.dismissedAlerts.single.studentId, heavy);
    expect(await f.alertOf(heavy), isNull);
  });

  test('حذف الإجازة يعيد الغياب فيعود الطالب إلى التنبيهات', () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int heavy = await f.student('كثير الغياب', absentDays: 15);
    await f.alerts.sync();
    await f.leaves.add(yearId: f.yearId, draft: f.draft(heavy, 1, 15));
    expect(await f.alertOf(heavy), isNull);

    final LeaveChange change = await f.leaves.delete(await f.onlyLeave());

    expect(change.syncedLessons, 15);
    expect(change.dismissedAlerts, isEmpty);
    expect(await f.db.select(f.db.leaves).get(), isEmpty);
    await f.alerts.sync();
    expect(await f.alertOf(heavy), isNotNull);
  });

  test('عتبة مطفأة (0) لا تُزيل أي تنبيه محفوظ', () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int heavy = await f.student('كثير الغياب', absentDays: 15);
    await f.alerts.sync();
    await f.db.setSetting('alert_threshold_2', '0');

    final LeaveChange change =
        await f.leaves.add(yearId: f.yearId, draft: f.draft(heavy, 1, 15));

    expect(change.dismissedAlerts, isEmpty);
    expect(await f.alertOf(heavy), isNotNull);
  });

  test('مسودة غير صالحة تُرفض قبل أي كتابة', () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int s = await f.student('طالب', absentDays: 1);

    await expectLater(
      f.leaves.add(yearId: f.yearId, draft: f.draft(s, 3, 1)),
      throwsArgumentError,
    );
    await expectLater(
      f.leaves.add(
        yearId: f.yearId,
        draft: LeaveDraft(
          studentId: s,
          start: _day(1),
          end: _day(1),
          type: 0,
          fromSlot: 4,
          toSlot: 2,
        ),
      ),
      throwsArgumentError,
    );
    await expectLater(
      f.leaves.add(
        yearId: f.yearId,
        draft: LeaveDraft(studentId: s, start: _day(1), end: _day(1), type: 9),
      ),
      throwsArgumentError,
    );
    expect(await f.db.select(f.db.leaves).get(), isEmpty);
    expect(await f.statusOn(s, 1), AttendanceStatus.absent);
  });

  test('تعديل إجازة محذوفة يرمي LeaveNotFoundException ويرتدّ بلا أثر', () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int s = await f.student('طالب', absentDays: 2);
    await f.leaves.add(yearId: f.yearId, draft: f.draft(s, 1, 1));
    final Leave stale = await f.onlyLeave();
    await f.leaves.delete(stale);

    await expectLater(
      f.leaves.update(stale, f.draft(s, 1, 2)),
      throwsA(isA<LeaveNotFoundException>()),
    );
    expect(await f.db.select(f.db.leaves).get(), isEmpty);
    expect(await f.statusOn(s, 1), AttendanceStatus.absent);
    expect(await f.statusOn(s, 2), AttendanceStatus.absent);
  });

  test('LeaveDraft.of يطابق السطر المحفوظ', () async {
    final _Fixture f = await _fixture();
    addTearDown(f.db.close);
    final int s = await f.student('طالب', absentDays: 0);
    await f.leaves.add(
      yearId: f.yearId,
      draft: LeaveDraft(
        studentId: s,
        start: _day(4),
        end: _day(6),
        type: 1,
        fromSlot: 2,
        reason: 'سفر',
      ),
    );
    final LeaveDraft d = LeaveDraft.of(await f.onlyLeave());
    expect(d.studentId, s);
    expect(d.start, _day(4));
    expect(d.end, _day(6));
    expect(d.type, 1);
    expect(d.fromSlot, 2);
    expect(d.toSlot, isNull);
    expect(d.reason, 'سفر');
  });
}
