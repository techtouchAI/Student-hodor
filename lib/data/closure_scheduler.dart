/// جدولة الإقفال التلقائي للحضور والغياب.
///
/// الآلية: كل (صف، تاريخ، حصة) له **مهمة إقفال** في جدول `closure_tasks`
/// (مصدر الحقيقة، لا ذاكرة التطبيق). موعد المهمة هو **نهاية الحصة** من
/// جدول الحصص الفعلي، وتُجدَّد المهمة من البيانات الفعلية في كل تشغيل
/// (لا مواعيد مخزّنة قديمة). الاسترداد المستقل عن الجدولة:
///
/// 1. **استرداد عند التشغيل** (`startup`/`recoverDue`): كل مهمة معلقة تأخر
///    موعدها تُنفَّذ فوراً — يغطي إغلاق التطبيق، قتله من قائمة التطبيقات،
///    إعادة تشغيل الهاتف، ومنع Android تنفيذ المهمة في موعدها.
/// 2. **AlarmManager أصلي** (`MethodChannelClosureBridge` في `core/`): يصل
///    إلى موعد النهاية بدقة (أو بشكل غير دقيق مع تقييدات النظام)، ويُعيد
///    إطلاق التطبيق الذي ينفّذ الاسترداد. آلية الاسترداد هي الضمانة
///    الأساسية: حتى لو مُنع التنبيه، يُنفَّذ الإقفال عند التشغيل التالي.
/// 3. **BootReceiver**: بعد إعادة تشغيل الهاتف يُعيد ترتيب التنبيهات من
///    ملفان الجدولة المكتوب على القرص (لا يفتح التطبيق).
///
/// الإقفال نفسه يُعيد استخدام المنطق الموجود: [AppDb.openLessonSession] +
/// [AppDb.closeSession] (ذرّي، معارفة بالتكرار، يحترم الإجازات) — لا منطق
/// موازٍ. التنفيذ ذرّي من جهة القيد الفريد (صف، تاريخ، حصة) في المهمة
/// وقيد (طالب، تاريخ، حصة) في الحضور، فلا سجلات غياب مكررة ولا تعارض
/// بين الإقفال التلقائي واليدوي.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import '../core/late_time.dart';
import '../core/lesson.dart';
import '../core/school_time.dart';
import 'db.dart';

/// مهمة جدولة مُسلَّمة للطبقة الأصلية (AlarmManager): معرّف + تاريخ + وقت.
class ClosureArmedTask {
  const ClosureArmedTask({
    required this.id,
    required this.date,
    required this.time,
  });

  final int id;
  final String date;
  final String time;
}

/// جسر إلى جدولة النظام الأصلية. التنفيذ الفعلي (MethodChannel) غير
/// متاح في الاختبارات — تُمرَّر [NoopClosureBridge] ليبقى منطق الربط
/// قابلاً للاختبار بدون جهاز.
abstract class NativeClosureBridge {
  /// يُعيد ترتيب التنبيهات للمهمة المُعطاة. الفشل غير قاتل: الاسترداد
  /// عند التشغيل هو الضمانة الأساسية.
  Future<void> arm(List<ClosureArmedTask> tasks);

  /// إلغاء كل التنبيهات المرتبة سابقاً.
  Future<void> cancelAll();
}

/// جسر للاختبارات: لا يربط بالطبقة الأصلية، وجدولة التنبيهات تُهمَل
/// (الاسترداد من القاعدة هو ما يُختبر).
class NoopClosureBridge implements NativeClosureBridge {
  const NoopClosureBridge();

  @override
  Future<void> arm(List<ClosureArmedTask> tasks) async {}

  @override
  Future<void> cancelAll() async {}
}

/// نتيجة تنفيذ مهمة إقفال واحدة.
enum ClosureExecutionStatus { executed, skipped, notDue, failed }

class ClosureExecution {
  const ClosureExecution({
    required this.taskId,
    required this.status,
    this.records = 0,
    this.message = '',
  });

  final int taskId;
  final ClosureExecutionStatus status;
  /// عدد سجلات الغياب/الإجازة التي ولّدها الإقفال (0 إن كانت مغلقة مسبقاً).
  final int records;
  final String message;

  bool get isExecuted => status == ClosureExecutionStatus.executed;
}

class ClosureScheduler {
  ClosureScheduler(this.db, {NativeClosureBridge? bridge})
      : _bridge = bridge ?? const NoopClosureBridge();

  final AppDb db;
  final NativeClosureBridge _bridge;

  /// مقبض واحد داخل العملية: لا تنفيذين متداخلين لمهمة الإقفال.
  static bool _busy = false;

  /// اسم ملف الجدولة الذي يقرأه BootReceiver بعد إعادة تشغيل الهاتف.
  static const String manifestName = 'closure_schedule.json';

  /// تشغيل واحد عند إقلاع التطبيق: استرداد المتأخرة ثم إعادة بناء جدولة
  /// اليوم والغد من البيانات الفعلية. لا يعتمد على بقاء أي شاشة مفتوحة.
  Future<void> startup({DateTime? now}) async {
    await recoverDue(now: now);
    await refreshSchedule(now: now);
  }

  /// تنفيذ كل المهمات المعلقة التي تأخر موعدها. يُعيد عدد ما نُفذ.
  ///
  /// هذه هي آلية الاسترداد المستقلة عن نجاح الجدولة: حتى لو منع أندرويد
  /// تشغيل التنبيه، يُنفَّذ الإقفال عند تشغيل التطبيق (أو عودته للواجهة).
  Future<int> recoverDue({DateTime? now}) async {
    final DateTime at = now ?? DateTime.now();
    final List<ClosureTask> pending = await db.pendingClosureTasks();
    int executed = 0;
    for (final ClosureTask task in pending) {
      final DateTime? target = _parseTarget(task.targetAt);
      // المهمة المستقبلية لا تُنفَّذ مبكراً، والمهمات بلا موعد صالح
      // تُترك للملاحظة (لا تنفيذ بلا وقت).
      if (target == null || target.isAfter(at)) {
        continue;
      }
      final ClosureExecution outcome = await executeTask(task.id, now: at);
      if (outcome.isExecuted) {
        executed++;
      }
    }
    return executed;
  }

  /// يعيد بناء جدولة الإقفال من **البيانات الفعلية** (الحصص، الصفوف،
  /// أيام الدوام، العطل): اليوم والغد فقط، بموعد نهاية كل حصة.
  ///
  /// تُحذف المهمات المعلقة القديمة (حصص حُذفت أو أيام غير دوام) وتُرتَّب
  /// التنبيهات من جديد. التنفيذ التاريخي (المهمات المُنفَّذة) يبقى سجلاً.
  Future<int> refreshSchedule({DateTime? now}) async {
    final DateTime at = now ?? DateTime.now();
    final AcademicYear? year = await db.activeYear();
    if (year == null) {
      // بلا سنة فعّالة لا جدولة: المهمات المعلقة لليوم تُحذف كي لا تُنفَّذ
      // بلا سياق.
      await db.deletePendingClosureTasksForDate(SchoolTime.dateKey(at));
      await _arm(<ClosureArmedTask>[]);
      return 0;
    }
    final Map<String, String> settings = await db.effectiveSettings();
    final List<Lesson> lessons = await db.allLessons();
    final List<SchoolClass> classes = await (db.select(db.schoolClasses)
          ..where((c) => c.yearId.equals(year.id)))
        .get();

    // يوما الجدولة: اليوم والغد. الغد يُرتَّب اليوم كي تصل التنبيهات حتى
    // لو لم يُفتح التطبيق بين عشية وضحاها (أو بعد إعادة تشغيل الهاتف).
    final List<String> dates = <String>[];
    for (final DateTime d in <DateTime>[at, at.add(const Duration(days: 1))]) {
      final String key = SchoolTime.dateKey(d);
      if (!await _isSchoolDay(d, settings)) {
        // يوم عطلة أو غير دوام: لا مهام، والمهمات المعلقة له تُحذف.
        await db.deletePendingClosureTasksForDate(key);
        continue;
      }
      dates.add(key);
    }

    final List<int> currentLessonIds = <int>[for (final Lesson l in lessons) l.id];
    final List<int> currentClassIds = <int>[for (final SchoolClass c in classes) c.id];

    for (final String date in dates) {
      for (final SchoolClass c in classes) {
        for (final Lesson l in lessons) {
          final int? endMinutes = parseArrivalMinutes(l.end);
          if (endMinutes == null) {
            continue; // وقت تالف: لا موعد يمكن تحديده — تُتخطى الحصة.
          }
          final DateTime target = _dateAt(SchoolTime.parseKey(date), endMinutes);
          await db.upsertClosureTask(
            yearId: year.id,
            classId: c.id,
            date: date,
            lessonId: l.id,
            targetAt: _targetKey(target),
          );
        }
      }
      // مهمات اليوم المعلقة لحصة حُذفت أو صف حُذف: تُحذف (لا تنفيذ لها).
      await (db.delete(db.closureTasks)
            ..where(
              (t) =>
                  t.date.equals(date) &
                  t.state.equals(ClosureTaskState.pending) &
                  ((t.lessonId.isNotIn(currentLessonIds)) |
                      (t.classId.isNotIn(currentClassIds))),
            ))
          .go();
    }

    final List<ClosureArmedTask> armed = <ClosureArmedTask>[];
    for (final String date in dates) {
      for (final ClosureTask t in await db.pendingClosureTasksForDate(date)) {
        final DateTime? target = _parseTarget(t.targetAt);
        if (target == null) {
          continue;
        }
        armed.add(
          ClosureArmedTask(
            id: t.id,
            date: t.date,
            time: arrivalTimeString(target),
          ),
        );
      }
    }
    await _arm(armed);
    return armed.length;
  }

  /// إلغاء كل المهمات المعلقة وإعادة بناء الجدولة — يُستدعى بعد أي تغيير
  /// يطال الجدول (تعديل الحصص، تغيير أيام الدوام، تغيير السنة، استعادة
  /// نسخة احتياطية): الجدولة تُبنى من البيانات الفعلية لا من مواعيد قديمة.
  Future<int> cancelPendingAndRefresh({DateTime? now}) async {
    final int removed = await db.deleteAllPendingClosureTasks();
    await _bridge.cancelAll();
    await refreshSchedule(now: now);
    return removed;
  }

  /// تنفيذ مهمة واحدة. ذرّية من جهة القيد الفريد، ومعارَفة بالتكرار:
  /// تنفيذها مرتين يُنتج سجلات غياب واحدة لا أكثر.
  ///
  /// يُعيد [ClosureExecution]: `executed` إن أُقفلت الحصة (أو كانت مغلقة
  /// مسبقاً)، `skipped` إن كانت المهمة قد نُفذت أو نُفذ تنفيذ متداخل،
  /// `notDue` إن لم يحن الموعد، و`failed` مع سبب الفشل إن تعذّر التنفيذ.
  Future<ClosureExecution> executeTask(
    int taskId, {
    DateTime? now,
  }) async {
    if (_busy) {
      return const ClosureExecution(
        taskId: -1,
        status: ClosureExecutionStatus.skipped,
        message: 'تنفيذ إقفال آخر جارٍ — تُتخطى المهمة',
      );
    }
    final ClosureTask? task =
        await (db.select(db.closureTasks)..where((t) => t.id.equals(taskId)))
            .getSingleOrNull();
    if (task == null || task.state != ClosureTaskState.pending) {
      return ClosureExecution(
        taskId: taskId,
        status: ClosureExecutionStatus.skipped,
        message: 'المهمة نُفذت مسبقاً أو أُزيلت — لا تنفيذ مكرر',
      );
    }
    final DateTime at = now ?? DateTime.now();
    final DateTime? target = _parseTarget(task.targetAt);
    if (target != null && at.isBefore(target)) {
      return ClosureExecution(
        taskId: taskId,
        status: ClosureExecutionStatus.notDue,
        message: 'موعد الإقفال لم يحن بعد',
      );
    }
    _busy = true;
    try {
      // الجلسة قد لا تكون مفتوحة (لم يمسح أحد): تُفتح ثم تُقفل، فيُحتسب
      // كل من لم يسجل حضوره غائباً — سلوك الإقفال العادي نفسه.
      final Session? existing = await db.sessionOf(
        task.classId,
        task.date,
        task.lessonId,
      );
      final Session session = existing ??
          await db.openLessonSession(
            yearId: task.yearId,
            classId: task.classId,
            date: task.date,
            lessonId: task.lessonId,
          );
      final int generated = await db.closeSession(session.id);
      final String outcome = generated > 0 ? 'closed' : 'already_closed';
      await db.markClosureTaskExecuted(
        task.id,
        executedAt: DateTime.now().toIso8601String(),
        result: outcome,
      );
      await db.logAudit(
        'closure_auto_closed',
        'task=$taskId lesson=${task.lessonId} class=${task.classId} '
        'date=${task.date} records=$generated',
      );
      return ClosureExecution(
        taskId: task.id,
        status: ClosureExecutionStatus.executed,
        records: generated,
        message: outcome,
      );
    } catch (e) {
      await db.markClosureTaskFailed(task.id, error: '$e');
      await db.logAudit('closure_auto_failed', 'task=$taskId error=$e');
      return ClosureExecution(
        taskId: task.id,
        status: ClosureExecutionStatus.failed,
        message: '$e',
      );
    } finally {
      _busy = false;
    }
  }

  /// يُرتّب التنبيهات الأصلية ويكتب ملفان BootReceiver. أي فشل في كتابة
  /// الملف لا يؤثر على الاسترداد من القاعدة.
  Future<void> _arm(List<ClosureArmedTask> tasks) async {
    await _bridge.arm(tasks);
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/$manifestName').writeAsString(
        const JsonEncoder.withIndent(' ')
            .convert(<Map<String, Object>>[
          for (final ClosureArmedTask t in tasks)
            <String, Object>{
              'id': t.id,
              'date': t.date,
              'time': t.time,
            },
        ]),
      );
    } catch (_) {
      // كتابة الملف مساعدة لل BootReceiver: الاسترداد من القاعدة يغني عنه.
    }
  }

  Future<bool> _isSchoolDay(DateTime day, Map<String, String> settings) async {
    return isSchoolDay(db, day, settings);
  }

  /// هل [day] يوم دوام (أيام الدوام الأسبوعية + العطل)؟ مشترك بين جدولة
  /// الإقفال وتنبيهات بداية/نهاية الحصة — مصدر واحد للقاعدة.
  static Future<bool> isSchoolDay(
    AppDb db,
    DateTime day,
    Map<String, String> settings,
  ) async {
    final Set<int> weekdays = <int>{
      for (final String w
          in (settings['work_weekdays'] ?? '7,1,2,3,4').split(','))
        int.tryParse(w) ?? 0,
    };
    final List<Holiday> holidays = await db.select(db.holidays).get();
    return SchoolTime.isSchoolDay(
      day,
      workWeekdays: weekdays,
      holidayKeys: <String>{for (final Holiday h in holidays) h.date},
    );
  }

  static DateTime _dateAt(DateTime day, int minutes) => DateTime(
        day.year,
        day.month,
        day.day,
        minutes ~/ 60,
        minutes % 60,
      );

  static String _targetKey(DateTime target) =>
      '${SchoolTime.dateKey(target)}T'
      '${target.hour.toString().padLeft(2, '0')}:'
      '${target.minute.toString().padLeft(2, '0')}:'
      '${target.second.toString().padLeft(2, '0')}';

  static DateTime? _parseTarget(String raw) => DateTime.tryParse(raw);

  /// حالة الدوام للحصة لحظة [now] — مصدرها الجلسة والمهمة، لا التخمين.
  ///
  /// الحالات: لم يبدأ الدوام / الدوام جارٍ / انتهت مهلة الحضور /
  /// تم الإقفال التلقائي / تم الإقفال يدوياً / تعذّر الإقفال ويجري الاسترداد.
  static String closureStatusLabel({
    required LessonWindow? lesson,
    required DateTime now,
    required String? closedAtIso,
    required int? taskState,
    required String? taskResult,
    required int lateAfterMinutes,
  }) {
    final LessonWindow? l = lesson;
    if (l == null) {
      return 'لا جدول حصص';
    }
    if (closedAtIso != null) {
      // مغلق: التلقائي هو من أغلق حين تكون المهمة مُنفَّذة بنتيجة «أُغلقت»،
      // وإلا فالإقفال كان يدوياً (مهمة غير مُنفَّذة، أو نُفذت بعد أن كان
      // مغلقاً مسبقاً).
      if (taskState == ClosureTaskState.executed && taskResult == 'closed') {
        return 'تم الإقفال التلقائي';
      }
      return 'تم الإقفال يدوياً';
    }
    if (taskState == ClosureTaskState.failed) {
      return 'تعذّر الإقفال التلقائي — يجري الاسترداد';
    }
    final int? start = parseArrivalMinutes(l.start);
    final int nowMinutes = now.hour * 60 + now.minute;
    final int startMinutes = start ?? 8 * 60;
    if (nowMinutes < startMinutes) {
      return 'لم يبدأ الدوام';
    }
    if (nowMinutes < startMinutes + lateAfterMinutes) {
      return 'الدوام جارٍ';
    }
    return 'انتهت مهلة الحضور';
  }
}
