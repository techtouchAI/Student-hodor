/// جدول الحصص: قواعد التحقق والاختيار (دوال نقية)، ثم العقد مع قاعدة
/// البيانات: تفرّد السجل لكل حصة، إقفال حصة لا يمسّ غيرها، وحماية الحصص
/// التي لها سجلات من الحذف.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/lesson.dart';
import 'package:student_hodor/data/db.dart';
import 'package:student_hodor/data/reports_service.dart';

LessonWindow _w(int id, int slot, String start, String end, [String name = '']) =>
    LessonWindow(id: id, slot: slot, name: name, start: start, end: end);

Future<(AppDb, int, int, int)> _seed() async {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
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
  final int studentId = await db.addStudent(
    yearId: yearId,
    classId: classId,
    fullName: 'علي حسن',
  );
  return (db, yearId, classId, studentId);
}

void main() {
  group('قواعد الجدول (دوال نقية)', () {
    test('الجدول الافتراضي صالح: ست حصص متتابعة بلا تداخل', () {
      final List<LessonWindow> windows = <LessonWindow>[
        for (final LessonTemplate t in LessonSchedule.defaults)
          _w(t.slot, t.slot, t.start, t.end, t.name),
      ];
      expect(windows.length, LessonSchedule.defaultCount);
      expect(LessonSchedule.validate(windows), isNull);
    });

    test('التحقق يرفض التداخل والنهاية قبل البداية والجدول الفارغ', () {
      expect(LessonSchedule.validate(const <LessonWindow>[]), isNotNull);
      expect(
        LessonSchedule.validate(<LessonWindow>[_w(1, 1, '09:00', '09:00')]),
        isNotNull,
      );
      final String? overlap = LessonSchedule.validate(<LessonWindow>[
        _w(1, 1, '08:00', '09:00'),
        _w(2, 2, '08:30', '09:30'),
      ]);
      expect(overlap, isNotNull);
      expect(overlap!, contains('تتداخل'));
      // فجوة استراحة مسموحة (لا تداخل).
      expect(
        LessonSchedule.validate(<LessonWindow>[
          _w(1, 1, '08:00', '08:45'),
          _w(2, 2, '09:00', '09:45'),
        ]),
        isNull,
      );
    });

    test('اختيار الحصة: الجارية ثم التالية، وقبل الدوام الأولى', () {
      final List<LessonWindow> windows = <LessonWindow>[
        _w(1, 1, '08:00', '08:45'),
        _w(2, 2, '08:50', '09:35'),
        _w(3, 3, '09:40', '10:25'),
      ];
      expect(
        LessonSchedule.suggested(windows, DateTime(2026, 9, 13, 9, 0))?.slot,
        2,
        reason: 'داخل نافذة الحصة الثانية',
      );
      expect(
        LessonSchedule.suggested(windows, DateTime(2026, 9, 13, 9, 37))?.slot,
        3,
        reason: 'في الفجوة ⇒ الحصة التالية لا السابقة',
      );
      expect(
        LessonSchedule.suggested(windows, DateTime(2026, 9, 13, 7, 30))?.slot,
        1,
        reason: 'قبل الجرس ⇒ الأولى (المسح الصباحي)',
      );
      expect(
        LessonSchedule.suggested(windows, DateTime(2026, 9, 13, 18, 0))?.slot,
        3,
        reason: 'بعد آخر حصة ⇒ الأخيرة للتصحيح المتأخر',
      );
      expect(
        LessonSchedule.suggested(const <LessonWindow>[], DateTime.now()),
        isNull,
      );
    });

    test('نص نطاق الإجازة بأشكاله الأربعة', () {
      expect(leaveScopeLabel(), 'كل الحصص');
      expect(
        leaveScopeLabel(fromSlot: 3),
        'من ${LessonLabels.of(3)} حتى آخر اليوم',
      );
      expect(leaveScopeLabel(fromSlot: 3, toSlot: 5), 'الحصص 3–5');
      expect(leaveScopeLabel(fromSlot: 2, toSlot: 2), LessonLabels.of(2));
    });

    test('نطاق الحصة يغطي الحدين ويشمل الكل عند غياب الطرفين', () {
      expect(AppDb.slotInScope(1, null, null), isTrue);
      expect(AppDb.slotInScope(6, null, null), isTrue);
      expect(AppDb.slotInScope(3, 2, 4), isTrue);
      expect(AppDb.slotInScope(1, 2, 4), isFalse);
      expect(AppDb.slotInScope(5, 2, null), isTrue);
      expect(AppDb.slotInScope(1, null, 3), isTrue);
    });
  });

  group('العقد مع قاعدة البيانات', () {
    test('الحضور لكل حصة: غياب حصة لا يمسّ حصة أخرى', () async {
      final (AppDb db, int yearId, int classId, int studentId) = await _seed();
      addTearDown(db.close);
      final Lesson first = await db.firstLesson();
      final Lesson second = (await db.lessonBySlot(2))!;
      const String date = '2026-09-13';

      await db.upsertAttendance(
        yearId: yearId,
        classId: classId,
        studentId: studentId,
        date: date,
        lessonId: first.id,
        status: AttendanceStatus.present,
        source: AttendanceSource.scan,
        arrivalTime: '08:02',
      );
      final int sessionId = await db.into(db.sessions).insert(
            SessionsCompanion(
              yearId: Value(yearId),
              classId: Value(classId),
              date: const Value(date),
              lessonId: Value(second.id),
              openedAt: const Value('2026-09-13T08:50:00'),
            ),
          );
      expect(await db.closeSession(sessionId), 1);

      expect(await db.attendanceOf(studentId, date, first.id), isNotNull);
      final AttendanceRow? secondRow =
          await db.attendanceOf(studentId, date, second.id);
      expect(secondRow?.status, AttendanceStatus.absent);
      expect(secondRow?.source, AttendanceSource.autoClose);

      // العدّان: حصتان مسجّلتان (حضور + غياب) لكن الغياب في **يوم واحد**.
      final StatusTotals t =
          await ReportsService(db).totalsForStudent(studentId, yearId);
      expect(t.present, 1);
      expect(t.absent, 1);
      expect(t.absentDays, 1);
      expect(t.recordedDays, 1);
      expect(t.recorded, 2);
    });

    test('حفظ الجدول يحفظ الهوية ويحمي الحصص ذات السجلات', () async {
      final (AppDb db, int yearId, int classId, int studentId) = await _seed();
      addTearDown(db.close);
      final List<Lesson> seeded = await db.allLessons();
      expect(seeded.length, LessonSchedule.defaultCount);

      // تعديل الاسم + إضافة حصة سابعة: الهويات القديمة لا تُستبدل.
      await db.saveLessons(<LessonWindow>[
        for (final Lesson l in seeded)
          _w(
            l.id,
            l.slot,
            l.start,
            l.end,
            l.slot == 1 ? 'القراءة' : l.name,
          ),
        _w(0, seeded.length + 1, '13:00', '13:45', 'الحصة السابعة'),
      ]);
      final List<Lesson> after = await db.allLessons();
      expect(after.length, seeded.length + 1);
      expect(after.first.id, seeded.first.id);
      expect(after.first.name, 'القراءة');
      expect(after.last.start, '13:00');
      expect(after.last.slot, seeded.length + 1);

      // حصة بلا سجلات تُحذف بلا اعتراض.
      await db.saveLessons(<LessonWindow>[
        for (final Lesson l in after)
          if (l.slot != after.length) _w(l.id, l.slot, l.start, l.end, l.name),
      ]);
      expect((await db.allLessons()).length, seeded.length);

      // حصة لها سجل حضور لا تُحذف: تاريخ الطالب ليس قابلاً للمحو الصامت.
      await db.upsertAttendance(
        yearId: yearId,
        classId: classId,
        studentId: studentId,
        date: '2026-09-14',
        lessonId: seeded.first.id,
        status: AttendanceStatus.present,
        source: AttendanceSource.manual,
      );
      await expectLater(
        db.saveLessons(<LessonWindow>[
          for (final Lesson l in seeded)
            if (l.id != seeded.first.id) _w(l.id, l.slot, l.start, l.end),
        ]),
        throwsA(isA<LessonInUseException>()),
      );
      expect((await db.allLessons()).length, seeded.length);
    });
  });
}
