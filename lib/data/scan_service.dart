/// منطق قراءة الباجات: تحقق متعدد الطبقات + سجل أحداث + منع التكرار.
library;

import 'package:drift/drift.dart';

import '../core/badge_code.dart';
import 'db.dart';

class ScanOutcome {
  const ScanOutcome({required this.result, this.studentName, this.message = ''});

  final int result;
  final String? studentName;
  final String message;

  bool get isSuccess => result == ScanResult.ok;
}

class ScanService {
  ScanService(this.db);

  final AppDb db;

  Future<ScanOutcome> handleScan({
    required Session session,
    required String raw,
  }) async {
    final ParsedBadgeCode? parsed = BadgeCode.parse(raw);
    if (parsed == null) {
      await _log(session, raw, null, ScanResult.unknownCode);
      return const ScanOutcome(
        result: ScanResult.unknownCode,
        message: 'رمز غير معروف — تأكد أن الباج من هذا النظام',
      );
    }
    final Badge? badge = await (db.select(db.badges)
          ..where((b) => b.code.equals(parsed.code)))
        .getSingleOrNull();
    if (badge == null) {
      await _log(session, parsed.code, null, ScanResult.unknownCode);
      return const ScanOutcome(
        result: ScanResult.unknownCode,
        message: 'الرمز سليم لكنه غير مسجل في هذه القاعدة',
      );
    }
    if (badge.status == 1) {
      await _log(session, parsed.code, badge.studentId, ScanResult.revoked);
      return const ScanOutcome(
        result: ScanResult.revoked,
        message: 'باج مبطل (بدل فاقد) — أصدر باجاً جديداً للطالب',
      );
    }
    final Student? student = await (db.select(db.students)
          ..where((s) => s.id.equals(badge.studentId)))
        .getSingleOrNull();
    if (student == null) {
      await _log(session, parsed.code, badge.studentId, ScanResult.unknownCode);
      return const ScanOutcome(
        result: ScanResult.unknownCode,
        message: 'لا يوجد طالب مرتبط بهذا الباج',
      );
    }
    if (student.yearId != session.yearId) {
      await _log(session, parsed.code, student.id, ScanResult.wrongYear);
      return ScanOutcome(
        result: ScanResult.wrongYear,
        studentName: student.fullName,
        message: '${student.fullName}: باج سنة دراسية أخرى',
      );
    }
    if (student.classId != session.classId) {
      await _log(session, parsed.code, student.id, ScanResult.wrongClass);
      return ScanOutcome(
        result: ScanResult.wrongClass,
        studentName: student.fullName,
        message: '${student.fullName}: ليس من طلاب هذا الصف',
      );
    }
    if (session.closedAt != null) {
      await _log(session, parsed.code, student.id, ScanResult.sessionClosed);
      return ScanOutcome(
        result: ScanResult.sessionClosed,
        studentName: student.fullName,
        message: 'الجلسة مقفلة — أعد فتحها لتسجيل قراءات',
      );
    }
    final AttendanceRow? existing =
        await db.attendanceOf(student.id, session.date);
    if (existing != null &&
        (existing.status == AttendanceStatus.present ||
            existing.status == AttendanceStatus.late ||
            existing.status == AttendanceStatus.leave)) {
      await _log(session, parsed.code, student.id, ScanResult.duplicate);
      return ScanOutcome(
        result: ScanResult.duplicate,
        studentName: student.fullName,
        message: '${student.fullName}: مسجل مسبقاً',
      );
    }
    await db.upsertAttendance(
      yearId: session.yearId,
      classId: session.classId,
      studentId: student.id,
      date: session.date,
      status: AttendanceStatus.present,
      source: AttendanceSource.scan,
      sessionId: session.id,
    );
    await _log(session, parsed.code, student.id, ScanResult.ok);
    return ScanOutcome(
      result: ScanResult.ok,
      studentName: student.fullName,
      message: 'تم تسجيل حضور ${student.fullName}',
    );
  }

  Future<void> _log(
    Session session,
    String code,
    int? studentId,
    int result,
  ) async =>
      db.into(db.scanEvents).insert(
            ScanEventsCompanion(
              sessionId: Value(session.id),
              code: Value(code),
              studentId: Value(studentId),
              result: Value(result),
              at: Value(DateTime.now().toIso8601String()),
            ),
          );
}
