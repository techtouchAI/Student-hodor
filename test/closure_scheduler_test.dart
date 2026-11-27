import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/lesson.dart';
import 'package:student_hodor/data/closure_scheduler.dart';
import 'package:student_hodor/data/db.dart';

/// اختبارات جدولة الإقفال التلقائي: بناء المهمات من الجدول الفعلي، التكرار،
/// العطل وأيام غير الدوام، إعادة البناء بعد التغيير، والاسترداد المستقل عن
/// الجدولة (إعادة التشغيل، تغير الساعة، والفشل).
void main() {
  late AppDb db;

  setUp(() async {
    db = AppDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
  });

  Future<int> seedYearAndClass({bool active = true}) async {
    final int year = await db.into(db.academicYears).insert(
          AcademicYearsCompanion(
            name: Value(active ? '2026-2027' : 'قديمة'),
            start: const Value('2026-09-01'),
            end: const Value('2027-06-30'),
            active: Value(active),
          ),
        );
    final int cls = await db.into(db.schoolClasses).insert(
      SchoolClassesCompanion(
        yearId: Value(year),
        grade: const Value('السادس'),
        section: const Value('أ'),
      ),
    );
    return cls;
  }

  test('refreshSchedule يبني مهمة لكل (صف، حصة) لليوم والغد بمواعيد نهاية الحصة',
      () async {
    final int cls = await seedYearAndClass();
    final DateTime now = DateTime(2026, 9, 16, 7, 0); // أربعاء (يوم دوام)
    final scheduler = ClosureScheduler(db);

    final int armed = await scheduler.refreshSchedule(now: now);
    final List<ClosureTask> today = await db.pendingClosureTasksForDate('2026-09-16');

    expect(today, hasLength(LessonSchedule.defaults.length),
        reason: 'حصة واحدة لكل حصة في الجدول',);
    for (final ClosureTask t in today) {
      expect(t.classId, cls);
      final Lesson? l = await db.lessonById(t.lessonId);
      expect(t.targetAt,
          '2026-09-16T${l!.end}:00',
          reason: 'موعد الإقفال = نهاية الحصة الفعلية',);
    }
    expect(armed, LessonSchedule.defaults.length * 2,
        reason: 'التنبيهات المرتبة = اليوم والغد',);
  });

  test('لا مهام ليوم عطلة أو غير دوام، والمهمات المعلقة له تُحذف', () async {
    final int cls = await seedYearAndClass();
    // عطلة في 2026-09-16 (أربعاء) وتعديل أيام الدوام لإبعاد 2026-09-17 (خميس).
    await db.into(db.holidays).insert(
      const HolidaysCompanion(date: const Value('2026-09-16'), title: const Value('عطلة')),
    );
    await db.setSetting('work_weekdays', '7,1,2');

    final DateTime now = DateTime(2026, 9, 16, 7, 0);
    final scheduler = ClosureScheduler(db);
    await scheduler.refreshSchedule(now: now);

    expect(await db.pendingClosureTasksForDate('2026-09-16'), isEmpty,
        reason: 'يوم عطلة: لا مهام',);
    expect(await db.pendingClosureTasksForDate('2026-09-17'), isEmpty,
        reason: 'يوم غير دوام: لا مهام',);

    // مهمة معلقة سابقة لليوم العطلة تُحذف (لا تنفيذ لها).
    final Lesson first = await db.firstLesson();
    await db.upsertClosureTask(
      yearId: 1,
      classId: cls,
      date: '2026-09-16',
      lessonId: first.id,
      targetAt: '2026-09-16T08:45:00',
    );
    await scheduler.refreshSchedule(now: now);
    expect(await db.pendingClosureTasksForDate('2026-09-16'), isEmpty,
        reason: 'المهمات المعلقة ليوم العطلة تُحذف في إعادة البناء',);
  });

  test('لا تُنفَّذ مهام لمواعيد مستقبلية، ولا تُبنى مهام لما بعد الغد', () async {
    await seedYearAndClass();
    final DateTime now = DateTime(2026, 9, 16, 7, 0);
    final scheduler = ClosureScheduler(db);
    await scheduler.refreshSchedule(now: now);

    for (final ClosureTask t in await db.pendingClosureTasks()) {
      expect(t.date, isIn(<String>['2026-09-16', '2026-09-17']),
          reason: 'الجدول يغطي اليوم والغد فقط',);
    }
    final ClosureExecution early = await scheduler.executeTask(
      (await db.pendingClosureTasks()).first.id,
      now: DateTime(2026, 9, 16, 7, 0),
    );
    expect(early.status, ClosureExecutionStatus.notDue,
        reason: 'قبل الموعد لا تنفيذ مبكر',);
    expect(early.isExecuted, isFalse);
    expect(await db.pendingClosureTasks(), isNotEmpty,
        reason: 'المهمة تبقى معلقة',);
  });

  test('refreshSchedule متكرر لا يخلق مهام مكررة (التفرّد)', () async {
    await seedYearAndClass();
    final DateTime now = DateTime(2026, 9, 16, 7, 0);
    final scheduler = ClosureScheduler(db);
    await scheduler.refreshSchedule(now: now);
    await scheduler.refreshSchedule(now: now);

    expect(await db.pendingClosureTasks(),
        hasLength(LessonSchedule.defaults.length * 2),
        reason: 'الإعادة تُحدّث لا تُكرّر',);
  });

  test('تعديل الجدول يلغي المهمات المعلقة ويعيد بناءها من الحصص الجديدة',
      () async {
    await seedYearAndClass();
    final DateTime now = DateTime(2026, 9, 16, 7, 0);
    final scheduler = ClosureScheduler(db);
    await scheduler.refreshSchedule(now: now);

    // جدول جديد بحصتين تنتهي الأولى عند 09:00.
    await db.saveLessons(<LessonWindow>[
      const LessonWindow(id: 1, slot: 1, name: 'الحصة الأولى', start: '08:00', end: '09:00'),
      const LessonWindow(id: 2, slot: 2, name: 'الحصة الثانية', start: '09:05', end: '09:50'),
    ]);
    final int removed = await scheduler.cancelPendingAndRefresh(now: now);
    expect(removed, 4,
        reason: 'المهمات المتبقية (حصتين × يومَين) تُحذف؛ ما حذفه حفظ الجدول سبق',);
    final List<ClosureTask> tasks = await db.pendingClosureTasks();
    expect(tasks, hasLength(4), reason: 'حصتين × يومَين');
    final List<String> targets = <String>[
      for (final ClosureTask t in tasks)
        if (t.date == '2026-09-16') t.targetAt,
    ]..sort();
    expect(targets, <String>['2026-09-16T09:00:00', '2026-09-16T09:50:00']);
  });

  test('حذف حصة تحذف مهام إقفالها آلياً ثم يُعاد بناء الجدولة من الباقية',
      () async {
    await seedYearAndClass();
    final DateTime now = DateTime(2026, 9, 16, 7, 0);
    final scheduler = ClosureScheduler(db);
    await scheduler.refreshSchedule(now: now);

    // تحرير الجدول بحذف الحصص الأخرى: مهامها تُحذف معها (سجل جدولة،
    // لا سجل حضور) ولا يحبس الحذف بسببها.
    await db.saveLessons(<LessonWindow>[
      const LessonWindow(id: 1, slot: 1, name: 'الحصة الأولى', start: '08:00', end: '08:45'),
    ]);
    await scheduler.refreshSchedule(now: now);

    final List<ClosureTask> tasks = await db.pendingClosureTasks();
    expect(tasks, hasLength(2), reason: 'مهمة الحصة الباقية لليوم والغد');
    expect(
      tasks.every((ClosureTask t) => t.lessonId == 1),
      isTrue,
      reason: 'لا مهام لحصص حُذفت',
    );
    // سلامة المراجع بعد الحذف: لا مفتاح أجنبي معلّق.
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  test('لا جدولة بلا سنة فعّالة، والمهمات المعلقة لليوم تُحذف', () async {
    final _ = await seedYearAndClass(active: false);
    final DateTime now = DateTime(2026, 9, 16, 7, 0);
    final scheduler = ClosureScheduler(db);
    final int armed = await scheduler.refreshSchedule(now: now);
    expect(armed, 0);
    expect(await db.pendingClosureTasks(), isEmpty);
  });

  test('recoverDue يُنفّذ المهمات المتأخّرة بعد إعادة التشغيل أو تغير الساعة',
      () async {
    final int cls = await seedYearAndClass();
    // طالب واحد ليُولّد الإقفال غياباً له (نتيجة «أُغلقت»).
    await db.into(db.students).insert(
      StudentsCompanion(
        yearId: const Value(1),
        classId: Value(cls),
        fullName: const Value('طالب'),
        personKey: const Value('p1'),
        seq: const Value(1),
        createdAt: const Value('2026-09-01T08:00:00'),
      ),
    );
    final Lesson lesson = await db.firstLesson();
    await db.upsertClosureTask(
      yearId: 1,
      classId: cls,
      date: '2026-09-16',
      lessonId: lesson.id,
      targetAt: '2026-09-16T08:45:00',
    );

    final scheduler = ClosureScheduler(db);
    expect(
        await scheduler.recoverDue(now: DateTime(2026, 9, 16, 8, 0)), 0,
        reason: 'قبل الموعد لا تنفيذ',);

    final int executed =
        await scheduler.recoverDue(now: DateTime(2026, 9, 16, 9, 0));
    expect(executed, 1, reason: 'بعد الموعد يُنفّذ');
    final ClosureTask? t = await db.closureTaskOf(cls, '2026-09-16', lesson.id);
    expect(t?.state, ClosureTaskState.executed);
    expect(t?.result, 'closed');
  });

  test('تنفيذ المهمة مرتين لا يُولّد غياباً مكرراً (ذرّية)', () async {
    final int cls = await seedYearAndClass();
    final Lesson lesson = await db.firstLesson();
    for (int i = 1; i <= 2; i++) {
      await db.into(db.students).insert(
        StudentsCompanion(
          yearId: const Value(1),
          classId: Value(cls),
          fullName: Value('طالب $i'),
          personKey: Value('p$i'),
          seq: Value(i),
          createdAt: const Value('2026-09-01T08:00:00'),
        ),
      );
    }
    await db.upsertClosureTask(
      yearId: 1,
      classId: cls,
      date: '2026-09-16',
      lessonId: lesson.id,
      targetAt: '2026-09-16T08:45:00',
    );
    final scheduler = ClosureScheduler(db);

    final int first = await scheduler.recoverDue(
        now: DateTime(2026, 9, 16, 9, 0,);
    expect(first, 1, reason: 'التنفيذ الأول');
    final int second = await scheduler.recoverDue(
        now: DateTime(2026, 9, 16, 10, 0,);
    expect(second, 0, reason: 'لا تنفيذ مكرر');

    final List<AttendanceRow> rows = await db.select(db.attendanceRows).get();
    expect(rows, hasLength(2), reason: 'غياب واحد لكل طالب لا أكثر');
    expect(rows.every((AttendanceRow r) => r.status == AttendanceStatus.absent),
        isTrue,);
  });

  test('جلسة أُغلقت يدوياً قبل الموعد: الإقفال التلقائي لا يضيف غياباً',
      () async {
    final int cls = await seedYearAndClass();
    final Lesson lesson = await db.firstLesson();
    final Session session = await db.openLessonSession(
      yearId: 1,
      classId: cls,
      date: '2026-09-16',
      lessonId: lesson.id,
    );
    await db.closeSession(session.id);
    await db.upsertClosureTask(
      yearId: 1,
      classId: cls,
      date: '2026-09-16',
      lessonId: lesson.id,
      targetAt: '2026-09-16T08:45:00',
    );

    final scheduler = ClosureScheduler(db);
    expect(
        await scheduler.recoverDue(now: DateTime(2026, 9, 16, 9, 0)), 1,
        reason: 'تُسجّل المهمة كمنفّذة',);
    final List<AttendanceRow> rows = await db.select(db.attendanceRows).get();
    expect(rows, isEmpty, reason: 'لا غياب من إقفال تلقائي سبقته إقفال يدوي');
    final ClosureTask? t = await db.closureTaskOf(cls, '2026-09-16', lesson.id);
    expect(t?.result, 'already_closed');
  });

  test('مهمة فشلت تُعاد محاولتها في الاسترداد التالي', () async {
    final int cls = await seedYearAndClass();
    final Lesson lesson = await db.firstLesson();
    await db.upsertClosureTask(
      yearId: 1,
      classId: cls,
      date: '2026-09-16',
      lessonId: lesson.id,
      targetAt: '2026-09-16T08:45:00',
    );
    final List<ClosureTask> pending = await db.pendingClosureTasks();
    await db.markClosureTaskFailed(pending.first.id, error: 'اختبار');

    final ClosureTask? failed = await db.closureTaskOf(cls, '2026-09-16', lesson.id);
    expect(failed?.state, ClosureTaskState.failed);
    expect(failed?.attempts, 1);

    final scheduler = ClosureScheduler(db);
    // إعادة بناء الجدولة تُعيد المهمة الفاشلة كمعلّقة (محاولة جديدة):
    final int removed =
        await scheduler.cancelPendingAndRefresh(now: DateTime(2026, 9, 16, 7, 0));
    expect(removed, 0, reason: 'المهمة الفاشلة ليست معلقة فلا تُحذف');
    final ClosureTask? retried =
        await db.closureTaskOf(cls, '2026-09-16', lesson.id);
    expect(retried?.state, ClosureTaskState.pending,
        reason: 'تُعاد محاولتها في إعادة البناء',);
    expect(await scheduler.recoverDue(now: DateTime(2026, 9, 16, 9, 0)), 1);
    final ClosureTask? done =
        await db.closureTaskOf(cls, '2026-09-16', lesson.id);
    expect(done?.state, ClosureTaskState.executed);
  });

  test('تنفيذ مهمة أُنفّذت لا يُعاد (التفرّد يمنع التعارض)', () async {
    final int cls = await seedYearAndClass();
    final Lesson lesson = await db.firstLesson();
    await db.upsertClosureTask(
      yearId: 1,
      classId: cls,
      date: '2026-09-16',
      lessonId: lesson.id,
      targetAt: '2026-09-16T08:45:00',
    );
    final int id = (await db.pendingClosureTasks()).first.id;
    await db.markClosureTaskExecuted(
      id,
      executedAt: '2026-09-16T09:00:00',
      result: 'closed',
    );

    final ClosureExecution again =
        await ClosureScheduler(db).executeTask(id);
    expect(again.status, ClosureExecutionStatus.skipped);
    expect(again.message, contains('نُفذت'));
  });

  test('مهمة منفّذة لا تُمسّ حتى لو تغيّر موعد الحصة (سجل انتهاء)', () async {
    final int cls = await seedYearAndClass();
    final Lesson lesson = await db.firstLesson();
    await db.upsertClosureTask(
      yearId: 1,
      classId: cls,
      date: '2026-09-16',
      lessonId: lesson.id,
      targetAt: '2026-09-16T08:45:00',
    );
    final int id = (await db.pendingClosureTasks()).first.id;
    await db.markClosureTaskExecuted(
      id,
      executedAt: '2026-09-16T09:00:00',
      result: 'closed',
    );
    // تحديث الموعد لاحقاً (تعديل الجدول): السجل المنتهي يبقى كما هو.
    await db.upsertClosureTask(
      yearId: 1,
      classId: cls,
      date: '2026-09-16',
      lessonId: lesson.id,
      targetAt: '2026-09-16T10:00:00',
    );
    final ClosureTask? t = await db.closureTaskOf(cls, '2026-09-16', lesson.id);
    expect(t?.id, id);
    expect(t?.state, ClosureTaskState.executed);
    expect(t?.targetAt, '2026-09-16T08:45:00');
  });

  test('closureStatusLabel تُصوّر حالات الدوام من الجلسة والمهمة', () async {
    const lesson = LessonWindow(
      id: 1,
      slot: 1,
      name: 'الحصة الأولى',
      start: '08:00',
      end: '08:45',
    );
    final now = DateTime(2026, 9, 16, 7, 30);
    expect(
      ClosureScheduler.closureStatusLabel(
        lesson: lesson,
        now: now,
        closedAtIso: null,
        taskState: null,
        taskResult: null,
        lateAfterMinutes: 15,
      ),
      'لم يبدأ الدوام',
    );
    expect(
      ClosureScheduler.closureStatusLabel(
        lesson: lesson,
        now: DateTime(2026, 9, 16, 8, 5),
        closedAtIso: null,
        taskState: null,
        taskResult: null,
        lateAfterMinutes: 15,
      ),
      'الدوام جارٍ',
    );
    expect(
      ClosureScheduler.closureStatusLabel(
        lesson: lesson,
        now: DateTime(2026, 9, 16, 8, 30),
        closedAtIso: null,
        taskState: ClosureTaskState.pending,
        taskResult: null,
        lateAfterMinutes: 15,
      ),
      'انتهت مهلة الحضور',
    );
    expect(
      ClosureScheduler.closureStatusLabel(
        lesson: lesson,
        now: now,
        closedAtIso: '2026-09-16T08:46:00',
        taskState: ClosureTaskState.executed,
        taskResult: 'closed',
        lateAfterMinutes: 15,
      ),
      'تم الإقفال التلقائي',
    );
    expect(
      ClosureScheduler.closureStatusLabel(
        lesson: lesson,
        now: now,
        closedAtIso: '2026-09-16T08:46:00',
        taskState: null,
        taskResult: null,
        lateAfterMinutes: 15,
      ),
      'تم الإقفال يدوياً',
    );
    expect(
      ClosureScheduler.closureStatusLabel(
        lesson: lesson,
        now: now,
        closedAtIso: null,
        taskState: ClosureTaskState.failed,
        taskResult: 'خطأ',
        lateAfterMinutes: 15,
      ),
      contains('الاسترداد'),
    );
  });

  test('مهمات اليوم المتأخّرة تُبنى وتُسترد عند التشغيل، ولا تُعاد بعد التنفيذ',
      () async {
    await seedYearAndClass();
    // «الآن» بعد نهاية آخر حصة من اليوم: تُبنى مهام اليوم (مواعيد ماضية)
    // والغد، ويسترد التشغيل المهمات المتأخّرة.
    final DateTime now = DateTime(2026, 9, 16, 23, 0);
    final scheduler = ClosureScheduler(db);
    await scheduler.refreshSchedule(now: now);
    expect(await db.pendingClosureTasksForDate('2026-09-16'), isNotEmpty);
    expect(await db.pendingClosureTasksForDate('2026-09-17'), isNotEmpty);

    // تشغيل على غرار الإقلاع: استرداد ثم إعادة بناء.
    await scheduler.startup(now: now);
    expect(await db.pendingClosureTasksForDate('2026-09-16'), isEmpty,
        reason: 'متأخّرة نُفّذت',);
    expect(await db.pendingClosureTasksForDate('2026-09-17'), isNotEmpty,
        reason: 'مهام الغد لا تُنفّذ مبكراً',);
    // إعادة بناء أخرى لا تُعيد مهام اليوم المنفّذة.
    await scheduler.refreshSchedule(now: now);
    expect(await db.closureTasksOf('2026-09-16'),
        everyElement((ClosureTask t) => t.state == ClosureTaskState.executed),
        reason: 'المهمات المنفّذة سجل انتهاء ولا تُعاد',);
  });
}
