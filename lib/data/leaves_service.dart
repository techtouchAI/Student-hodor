/// خدمة الإجازات: المصدر الوحيد لكل تعديل على الإجازات (إضافة/تعديل/حذف).
///
/// كل عملية **ذرّية** (معاملة واحدة) وتشمل بالترتيب:
/// 1. كتابة سطر الإجازة.
/// 2. مزامنة سجلات الحضور داخل النطاق (`AppDb.syncLeaveToAttendance`):
///    الغياب المغطّى يصبح إجازة، وما خرج من التغطية يعود غيابًا.
/// 3. سطر تدقيق.
/// 4. إعادة تقييم تنبيه حد الفصل للطالب/الطلاب المتأثرين: من لم يعد عند
///    الحد يُزال تنبيهه (`NotificationsService.dismissResolvedAlerts`).
///
/// بعد الالتزام فقط تُلغى إشعارات النظام للتنبيهات المُزالة — لا نداء منصة
/// داخل المعاملة (لو ارتدّت لبقي التنبيه بلا إشعار).
library;

import 'package:drift/drift.dart';

import 'db.dart';
import 'notifications_service.dart';

/// أنواع الإجازة بترتيب العمود `Leaves.type`.
const List<String> leaveTypeNames = <String>['مرضية', 'عرضية', 'طارئة'];

/// إجازة كما يحررها المستخدم قبل الحفظ (إضافة أو تعديل).
class LeaveDraft {
  const LeaveDraft({
    required this.studentId,
    required this.start,
    required this.end,
    required this.type,
    this.fromSlot,
    this.toSlot,
    this.reason = '',
  });

  /// مسودة مطابقة لإجازة محفوظة (نقطة بداية حوار التعديل).
  factory LeaveDraft.of(Leave l) => LeaveDraft(
        studentId: l.studentId,
        start: l.start,
        end: l.end,
        type: l.type,
        fromSlot: l.fromSlot,
        toSlot: l.toSlot,
        reason: l.reason,
      );

  final int studentId;

  /// مفتاح التاريخ `yyyy-MM-dd` (نفس `SchoolTime.dateKey`).
  final String start;
  final String end;

  /// 0 = مرضية، 1 = عرضية، 2 = طارئة ([leaveTypeNames]).
  final int type;

  /// نطاق الحصص: `null` في الطرفين = كل حصص اليوم.
  final int? fromSlot;
  final int? toSlot;

  final String reason;

  /// يرمي [ArgumentError] لمسودة لا يجوز حفظها — حارس في طبقة البيانات
  /// لا يعتمد على تحقق الواجهة وحده.
  void validate() {
    if (start.compareTo(end) > 0) {
      throw ArgumentError('بداية الإجازة ($start) بعد نهايتها ($end)');
    }
    if (type < 0 || type >= leaveTypeNames.length) {
      throw ArgumentError.value(type, 'type', 'نوع إجازة غير معروف');
    }
    final int? from = fromSlot;
    final int? to = toSlot;
    if ((from != null && from < 1) || (to != null && to < 1)) {
      throw ArgumentError('رقم الحصة يبدأ من 1');
    }
    if (from != null && to != null && from > to) {
      throw ArgumentError('نطاق الحصص معكوس ($from–$to)');
    }
  }

  LeavesCompanion _columns() => LeavesCompanion(
        studentId: Value(studentId),
        start: Value(start),
        end: Value(end),
        fromSlot: Value(fromSlot),
        toSlot: Value(toSlot),
        type: Value(type),
        reason: Value(reason.trim()),
      );
}

/// الإجازة المطلوب تعديلها لم تعد موجودة (حُذفت من مكان آخر قبل الحفظ).
class LeaveNotFoundException implements Exception {
  const LeaveNotFoundException(this.leaveId);

  final int leaveId;

  @override
  String toString() => 'LeaveNotFoundException: الإجازة $leaveId لم تعد موجودة';
}

/// نتيجة عملية على إجازة.
class LeaveChange {
  const LeaveChange({
    required this.leaveId,
    required this.syncedLessons,
    required this.dismissedAlerts,
  });

  final int leaveId;

  /// عدد الحصص التي تحوّلت حالتها (غياب ⇄ إجازة) بسبب العملية.
  final int syncedLessons;

  /// تنبيهات حد الفصل التي أُزيلت لأن الطالب لم يعد عند الحد.
  final List<AlertNotification> dismissedAlerts;
}

class LeavesService {
  LeavesService(this.db);

  final AppDb db;

  /// إضافة إجازة لطالب في سنة.
  Future<LeaveChange> add({
    required int yearId,
    required LeaveDraft draft,
  }) async {
    draft.validate();
    return _commit(() async {
      final int id = await db.into(db.leaves).insert(
            draft._columns().copyWith(
                  yearId: Value(yearId),
                  createdAt: Value(DateTime.now().toIso8601String()),
                ),
          );
      final int synced = await _syncDraft(draft, added: true);
      await db.logAudit(
        'leave_add',
        'id=$id student=${draft.studentId} ${draft.start}→${draft.end}',
      );
      return _finish(
        leaveId: id,
        yearId: yearId,
        synced: synced,
        studentIds: <int>{draft.studentId},
      );
    });
  }

  /// تعديل إجازة محفوظة (الطالب/التواريخ/الحصص/النوع/السبب).
  ///
  /// يُكتب السطر الجديد **أولاً** ثم يُتراجع عن نطاق القديم: التراجع يعيد
  /// غيابًا ما خرج من التغطية فقط، لأن ما بقي داخل النطاق الجديد ما زال
  /// مغطّى بإجازة (`isOnLeave`) فلا يُمسّ. ثم يُطبَّق النطاق الجديد.
  ///
  /// يرمي [LeaveNotFoundException] إن لم تعد الإجازة موجودة، وترتدّ
  /// المعاملة بلا أي أثر.
  Future<LeaveChange> update(Leave existing, LeaveDraft draft) async {
    draft.validate();
    return _commit(() async {
      final int updated = await (db.update(db.leaves)
            ..where((Leaves l) => l.id.equals(existing.id)))
          .write(draft._columns());
      if (updated == 0) {
        throw LeaveNotFoundException(existing.id);
      }
      int synced = await _syncDraft(LeaveDraft.of(existing), added: false);
      synced += await _syncDraft(draft, added: true);
      await db.logAudit(
        'leave_edit',
        'id=${existing.id} student=${existing.studentId}→${draft.studentId} '
            '${existing.start}→${existing.end} => ${draft.start}→${draft.end}',
      );
      return _finish(
        leaveId: existing.id,
        yearId: existing.yearId,
        synced: synced,
        studentIds: <int>{existing.studentId, draft.studentId},
      );
    });
  }

  /// حذف إجازة: ما ألغته من غياب يعود غيابًا ما لم تغطّه إجازة أخرى.
  Future<LeaveChange> delete(Leave existing) => _commit(() async {
        await (db.delete(db.leaves)
              ..where((Leaves l) => l.id.equals(existing.id)))
            .go();
        final int synced =
            await _syncDraft(LeaveDraft.of(existing), added: false);
        await db.logAudit('leave_delete', 'id=${existing.id}');
        return _finish(
          leaveId: existing.id,
          yearId: existing.yearId,
          synced: synced,
          studentIds: <int>{existing.studentId},
        );
      });

  /// معاملة واحدة، ثم إلغاء إشعارات النظام للتنبيهات المُزالة بعد الالتزام.
  Future<LeaveChange> _commit(Future<LeaveChange> Function() body) async {
    final LeaveChange change = await db.transaction<LeaveChange>(body);
    await NotificationsService.cancelSystemAlerts(change.dismissedAlerts);
    return change;
  }

  Future<int> _syncDraft(LeaveDraft d, {required bool added}) =>
      db.syncLeaveToAttendance(
        studentId: d.studentId,
        start: d.start,
        end: d.end,
        added: added,
        fromSlot: d.fromSlot,
        toSlot: d.toSlot,
      );

  Future<LeaveChange> _finish({
    required int leaveId,
    required int yearId,
    required int synced,
    required Set<int> studentIds,
  }) async =>
      LeaveChange(
        leaveId: leaveId,
        syncedLessons: synced,
        dismissedAlerts: await NotificationsService(db).dismissResolvedAlerts(
          yearId: yearId,
          studentIds: studentIds,
        ),
      );
}
