/// R2: دلالة الغياب الجزئي — المصدر الوحيد لتسمية اليوم ولونه.
///
/// القاعدة: «غائب» لا تُقال إلا إذا غاب الطالب عن كل حصص الجدول؛ غياب حصة أو
/// حصتين «غياب جزئي» بعددٍ صريح، والعدّاد القانوني `absentDays` لا يتغيّر.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/attendance_labels.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/reports_service.dart';

Map<int, int> _day(List<int> statuses) => <int, int>{
      for (int i = 0; i < statuses.length; i++) i + 1: statuses[i],
    };

void main() {
  const int present = AttendanceStatus.present;
  const int absent = AttendanceStatus.absent;
  const int leave = AttendanceStatus.leave;

  test('غياب حصة واحدة من ست: جزئي وليس «غائب»', () {
    final DayPresence day = describeDay(
      status: AttendanceStatus.absent,
      lessonStatuses: _day(<int>[present, absent, present, present, present, present]),
      totalLessons: 6,
    );
    expect(day.absence, DayAbsence.partial);
    expect(day.isPartial, isTrue);
    expect(day.label, 'غياب جزئي — غاب عن حصة واحدة');
    expect(day.label, isNot('غائب'));
    expect(day.absentLessons, 1);
  });

  test('غياب حصتين: «حصتان» بالنص العربي الصحيح', () {
    final DayPresence day = describeDay(
      status: AttendanceStatus.absent,
      lessonStatuses: _day(<int>[absent, absent, present, present, present, present]),
      totalLessons: 6,
    );
    expect(day.label, 'غياب جزئي — غاب عن حصتان');
    expect(arabicLessonCount(3), '3 حصص');
    expect(arabicLessonCount(11), '11 حصة');
  });

  test('غياب كل حصص الجدول: «غياب كامل»', () {
    final DayPresence day = describeDay(
      status: AttendanceStatus.absent,
      lessonStatuses: _day(<int>[absent, absent, absent, absent, absent, absent]),
      totalLessons: 6,
    );
    expect(day.absence, DayAbsence.full);
    expect(day.label, 'غياب كامل');
  });

  test('يوم حاضر أو بإجازة: يبقى نصه الحالي', () {
    expect(
      describeDay(
        status: present,
        lessonStatuses: _day(<int>[present, present]),
        totalLessons: 6,
      ).label,
      'حاضر',
    );
    expect(
      describeDay(
        status: leave,
        lessonStatuses: _day(<int>[leave, leave, leave, leave, leave, leave]),
        totalLessons: 6,
      ).label,
      'إجازة',
    );
    expect(
      describeDay(
        status: null,
        lessonStatuses: const <int, int>{},
        totalLessons: 6,
      ).label,
      'لم يُسجَّل',
    );
  });

  test('لون اليوم: باهت للجزئي وأحمر للكامل', () {
    final Color partial = dayStatusColor(
      status: AttendanceStatus.absent,
      lessonStatuses: _day(<int>[present, absent, present]),
      totalLessons: 6,
    );
    final Color full = dayStatusColor(
      status: AttendanceStatus.absent,
      lessonStatuses: _day(<int>[absent, absent, absent, absent, absent, absent]),
      totalLessons: 6,
    );
    expect(partial, partialAbsentColor);
    expect(partial, isNot(Colors.red));
    expect(full, Colors.red);
  });

  test('العدّاد القانوني يبقى يومياً: ست حصص غياب في يوم = يوم واحد', () {
    final List<AttendanceRow> rows = <AttendanceRow>[
      for (int i = 1; i <= 6; i++)
        AttendanceRow(
          id: i,
          yearId: 1,
          classId: 1,
          studentId: 1,
          date: '2026-09-01',
          lessonId: i,
          status: AttendanceStatus.absent,
          source: AttendanceSource.autoClose,
          sessionId: i,
          note: null,
          arrivalTime: null,
        ),
    ];
    final StatusTotals totals = ReportsService.totalsOfRows(rows);
    expect(totals.absent, 6, reason: 'ست حصص غياب');
    expect(totals.absentDays, 1, reason: 'يوم واحد — العتبات تبقى قانونية');
    expect(
      describeDay(
        status: AttendanceStatus.absent,
        lessonStatuses: <int, int>{for (final AttendanceRow r in rows) r.lessonId: r.status},
        totalLessons: 6,
      ).label,
      'غياب كامل',
    );
  });
}
