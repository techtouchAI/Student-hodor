/// منطق قراءة الباجات: تحقق متعدد الطبقات + سجل أحداث + منع التكرار + نافذة تأخر
/// + تثبيت وقت الوصول الفعلي (ساعة ودقيقة) في سجل الحضور.
library;

import 'package:drift/drift.dart';

import '../core/badge_code.dart';
import '../core/late_time.dart';
import '../core/school_time.dart';
import 'db.dart';

class ScanOutcome {
  const ScanOutcome({
    required this.result,
    this.studentName,
    this.message = '',
    this.arrivalTime,
  });

  final int result;
  final String? studentName;
  final String message;

  /// وقت القراءة الفعلي `HH:mm` للنجاح (حضور أو تأخر) — `null` فيما سواها.
  final String? arrivalTime;

  bool get isSuccess =>
      result == ScanResult.ok || result == ScanResult.late;
}

class ScanService {
  ScanService(this.db);

  final AppDb db;

  /// حد قبول الحضور الكامل: بداية اليوم + دقائق السماح، وبعده «متأخر».
  static DateTime lateCutoff(Map<String, String> settings, String dateKey) {
    final DateTime day = SchoolTime.parseKey(dateKey);
    final List<String> hm = (settings['day_start'] ?? '08:00').split(':');
    final int h = int.tryParse(hm.first) ?? 8;
    final int m = hm.length > 1 ? (int.tryParse(hm[1]) ?? 0) : 0;
    final int extra = int.tryParse(settings['late_after_minutes'] ?? '15') ?? 15;
    return DateTime(day.year, day.month, day.day, h, m).add(
      Duration(minutes: extra),
    );
  }

  /// يقرأ باجاً ويسجّل الحضور/التأخر. [now] حقن وقت القراءة للاختبارات؛
  /// في الميدان يُؤخذ الوقت الفعلي لحظة المسح ويُثبَّت `HH:mm` في السجل —
  /// إن تجاوز المسح نهاية نافذة السماح فالحالة «متأخر» ومعه وقت وصوله.
  Future<ScanOutcome> handleScan({
    required Session session,
    required String raw,
    DateTime? now,
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
    final Map<String, String> settings = await db.effectiveSettings();
    final DateTime at = now ?? DateTime.now();
    final bool isLate = at.isAfter(lateCutoff(settings, session.date));
    final int status =
        isLate ? AttendanceStatus.late : AttendanceStatus.present;
    final String arrival = arrivalTimeString(at);
    await db.upsertAttendance(
      yearId: session.yearId,
      classId: session.classId,
      studentId: student.id,
      date: session.date,
      status: status,
      source: AttendanceSource.scan,
      sessionId: session.id,
      arrivalTime: arrival,
    );
    await _log(
      session,
      parsed.code,
      student.id,
      isLate ? ScanResult.late : ScanResult.ok,
    );
    if (!isLate) {
      return ScanOutcome(
        result: ScanResult.ok,
        studentName: student.fullName,
        message: 'تم تسجيل حضور ${student.fullName}',
        arrivalTime: arrival,
      );
    }
    final String dur = lateDurationLabel(
      latenessDuration(arrivalTime: arrival, dayStart: settings['day_start']),
    );
    return ScanOutcome(
      result: ScanResult.late,
      studentName: student.fullName,
      message: 'سُجّل متأخراً: ${student.fullName} — الساعة $arrival'
          '${dur.isEmpty ? '' : ' (تأخير $dur)'}',
      arrivalTime: arrival,
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
