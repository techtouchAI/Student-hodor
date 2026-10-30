/// R1: الحفاظ على المعنى التاريخي لنطاقات الإجازات عند حذف حصة أو إعادة
/// ترتيبها — نطاق الإجازة مخزّن **برقم الحصة**، والسجلات تشير إلى **معرّفها**.
///
/// كل اختبار يتحقق من الشيء الوحيد المهم: مجموعة الحصص التي تغطيها الإجازة
/// تبقى هي نفسها بعد أي تعديل على الجدول، أو تُرفض العملية صراحةً.
library;

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/lesson.dart';
import 'package:student_hodor/data/db.dart';

/// صف واحد بطالب واحد وسنة فعّالة — الجدول الافتراضي ست حصص (معرّفات 1..6).
Future<({AppDb db, int studentId, int classId})> _seed() async {
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
    fullName: 'طالب الإجازة',
  );
  return (db: db, studentId: studentId, classId: classId);
}

/// يحفظ الترتيب المعطى (قائمة معرّفات الحصص) ثم يعيد أرقامها الجديدة.
Future<Map<int, int>> _saveOrder(AppDb db, List<int> ids) async {
  final List<LessonWindow> windows = await db.lessonWindows();
  final Map<int, LessonWindow> byId = <int, LessonWindow>{
    for (final LessonWindow w in windows) w.id: w,
  };
  // `saveLessons` يكتب الرقم من النافذة نفسها لا من موضعها في القائمة،
  // فإعادة الترتيب تعني إعادة ترقيم صريحة (كما تفعل شاشة الحصص).
  await db.saveLessons(<LessonWindow>[
    for (int i = 0; i < ids.length; i++)
      LessonWindow(
        id: ids[i],
        slot: i + 1,
        name: byId[ids[i]]!.name,
        start: byId[ids[i]]!.start,
        end: byId[ids[i]]!.end,
      ),
  ]);
  return <int, int>{
    for (final LessonWindow w in await db.lessonWindows()) w.id: w.slot,
  };
}

/// إجازة مادّية: غياب في حصص النطاق ثم إجازة تُحَوِّل ذلك الغياب إلى إجازة.
Future<void> _leave(
  AppDb db, {
  required int studentId,
  required int classId,
  required int from,
  required int to,
  String date = '2026-09-20',
}) async {
  for (final LessonWindow l in await db.lessonWindows()) {
    if (!AppDb.slotInScope(l.slot, from, to)) {
      continue;
    }
    await db.upsertAttendance(
      yearId: 1,
      classId: classId,
      studentId: studentId,
      date: date,
      lessonId: l.id,
      status: AttendanceStatus.absent,
      source: AttendanceSource.autoClose,
    );
  }
  final int leaveId = await db.into(db.leaves).insert(
        LeavesCompanion.insert(
          yearId: 1,
          studentId: studentId,
          start: date,
          end: date,
          fromSlot: Value(from),
          toSlot: Value(to),
          type: 0,
          createdAt: '2026-09-19T08:00:00',
        ),
      );
  await db.syncLeaveToAttendance(
    studentId: studentId,
    start: date,
    end: date,
    added: true,
    fromSlot: from,
    toSlot: to,
  );
  expect(leaveId, greaterThan(0));
}

/// الحصص التي تغطيها الإجازة الآن (بترتيب الجدول الحالي).
Future<Set<int>> _covered(AppDb db) async {
  final Leave l = await db.select(db.leaves).getSingle();
  final List<LessonWindow> windows = await db.lessonWindows();
  return <int>{
    for (final LessonWindow w in windows)
      if (AppDb.slotInScope(w.slot, l.fromSlot, l.toSlot)) w.id,
  };
}

/// الحصص التي صارت حالتها «إجازة» فعلياً في السجلات.
Future<Set<int>> _leaveRows(AppDb db) async {
  final List<AttendanceRow> rows = await (db.select(db.attendanceRows)
        ..where((a) => a.status.equals(AttendanceStatus.leave)))
      .get();
  return <int>{for (final AttendanceRow r in rows) r.lessonId};
}

void main() {
  test('حذف حصة قبل النطاق: الإجازة تنتقل مع حصصها نفسها', () async {
    final (db: AppDb db, studentId: int studentId, classId: int classId) =
        await _seed();
    addTearDown(db.close);
    await _leave(db, studentId: studentId, classId: classId, from: 3, to: 5);
    final Set<int> before = await _covered(db);
    expect(before, <int>{3, 4, 5});

    // حذف الحصة الأولى (لا سجلات لها) ⇒ كل ما بعدها ينزل رقماً.
    await _saveOrder(db, <int>[2, 3, 4, 5, 6]);

    final Leave l = await db.select(db.leaves).getSingle();
    expect(l.fromSlot, 2, reason: 'النطاق يجب أن يتبع الحصص لا الأرقام');
    expect(l.toSlot, 4);
    expect(await _covered(db), before, reason: 'نفس الحصص المغطاة');
    expect(await _leaveRows(db), before, reason: 'السجلات المادّة لم تتغيّر');
    // والحصة السادسة (صارت 5) خارج النطاق.
    final Map<int, int> slots = <int, int>{
      for (final LessonWindow w in await db.lessonWindows()) w.id: w.slot,
    };
    expect(await db.isOnLeave(studentId, '2026-09-20', slot: slots[6]), isFalse);
  });

  test('حذف حصة داخل النطاق: يقلّ النطاق بواحد ويبقى مربوطاً بالحصص', () async {
    final (db: AppDb db, studentId: int studentId, classId: int classId) =
        await _seed();
    addTearDown(db.close);
    await _leave(db, studentId: studentId, classId: classId, from: 3, to: 5);

    // حذف الحصة الرابعة (داخل النطاق، بلا سجلات محفوظة لها؟ لا: صارت إجازة.
    // لذلك نحذف حصة لا سجلات لها ونُبقي الاختبار على النطاق: نحذف 4 بعد
    // إفراغ سجلاتها أولاً كما يفعل المستخدم عند التصحيح.)
    await db.deleteAttendance(studentId, '2026-09-20', lessonId: 4);
    await _saveOrder(db, <int>[1, 2, 3, 5, 6]);

    final Leave l = await db.select(db.leaves).getSingle();
    expect(l.fromSlot, 3);
    expect(l.toSlot, 4, reason: 'حصتان فقط بقيتا من الثلاث');
    expect(await _covered(db), <int>{3, 5});
  });

  test('حذف حصة بعد النطاق: النطاق لا يتغيّر', () async {
    final (db: AppDb db, studentId: int studentId, classId: int classId) =
        await _seed();
    addTearDown(db.close);
    await _leave(db, studentId: studentId, classId: classId, from: 3, to: 5);

    await _saveOrder(db, <int>[1, 2, 3, 4, 5]);

    final Leave l = await db.select(db.leaves).getSingle();
    expect(l.fromSlot, 3);
    expect(l.toSlot, 5);
    expect(await _covered(db), <int>{3, 4, 5});
  });

  test('إعادة الترتيب: النطاق يلحق بالحصص لا بالأرقام', () async {
    final (db: AppDb db, studentId: int studentId, classId: int classId) =
        await _seed();
    addTearDown(db.close);
    await _leave(db, studentId: studentId, classId: classId, from: 3, to: 5);

    // الحصة السادسة إلى الصفر: كل البقية تتزحزح رقماً واحداً.
    await _saveOrder(db, <int>[6, 1, 2, 3, 4, 5]);

    final Leave l = await db.select(db.leaves).getSingle();
    expect(l.fromSlot, 4);
    expect(l.toSlot, 6);
    expect(await _covered(db), <int>{3, 4, 5});
    expect(await _leaveRows(db), <int>{3, 4, 5});

    final Map<int, int> slots = <int, int>{
      for (final LessonWindow w in await db.lessonWindows()) w.id: w.slot,
    };
    expect(await db.isOnLeave(studentId, '2026-09-20', slot: slots[6]), isFalse);
    expect(await db.isOnLeave(studentId, '2026-09-20', slot: slots[3]), isTrue);
  });

  test('ترتيب يفرّق حصص الإجازة يُرفض ولا يترك أثراً', () async {
    final (db: AppDb db, studentId: int studentId, classId: int classId) =
        await _seed();
    addTearDown(db.close);
    await _leave(db, studentId: studentId, classId: classId, from: 3, to: 4);

    // الحصة 3 تصبح 4 والحصة 4 تصبح 6 ⇒ لا يمكن التعبير عنهما كنطاق واحد.
    await expectLater(
      _saveOrder(db, <int>[1, 2, 5, 3, 6, 4]),
      throwsA(isA<LeaveScopeConflictException>()),
    );

    final List<LessonWindow> windows = await db.lessonWindows();
    expect(
      <int>[for (final LessonWindow w in windows) w.id],
      <int>[1, 2, 3, 4, 5, 6],
      reason: 'المعاملة ارتدّت: الترتيب القديم كما هو',
    );
    final Leave l = await db.select(db.leaves).getSingle();
    expect(l.fromSlot, 3);
    expect(l.toSlot, 4);
    expect(await _covered(db), <int>{3, 4});
  });

  test('تطابق isOnLeave مع السجلات بعد الحذف (لا حالة محتسبة مخالفة)', () async {
    final (db: AppDb db, studentId: int studentId, classId: int classId) =
        await _seed();
    addTearDown(db.close);
    await _leave(db, studentId: studentId, classId: classId, from: 3, to: 5);
    await _saveOrder(db, <int>[2, 3, 4, 5, 6]);

    final List<LessonWindow> windows = await db.lessonWindows();
    for (final LessonWindow w in windows) {
      final bool covered =
          await db.isOnLeave(studentId, '2026-09-20', slot: w.slot);
      final AttendanceRow? row =
          await db.attendanceOf(studentId, '2026-09-20', w.id);
      expect(
        row == null ? false : row.status == AttendanceStatus.leave,
        covered,
        reason: 'الحصة ${w.slot}: المحتسب يجب أن يطابق السجل المادّي',
      );
    }

    // إقفال حصة داخل النطاق يحترم الإجازة (لا يحوّلها إلى غياب).
    final Session session = await db.openLessonSession(
      yearId: 1,
      classId: classId,
      date: '2026-09-21',
      lessonId: windows[1].id, // صار رقم 2 داخل النطاق 2..4
    );
    await db.closeSession(session.id);
    final AttendanceRow? closed =
        await db.attendanceOf(studentId, '2026-09-21', windows[1].id);
    expect(closed?.status, AttendanceStatus.leave);

    // وحصة خارج النطاق تُقفل غياباً.
    final Session outside = await db.openLessonSession(
      yearId: 1,
      classId: classId,
      date: '2026-09-21',
      lessonId: windows.last.id,
    );
    await db.closeSession(outside.id);
    final AttendanceRow? absentRow =
        await db.attendanceOf(studentId, '2026-09-21', windows.last.id);
    expect(absentRow?.status, AttendanceStatus.absent);
  });

  test('إجازة «كل الحصص» تبقى كل الحصص بعد الحذف', () async {
    final (db: AppDb db, studentId: int studentId, classId: int classId) =
        await _seed();
    addTearDown(db.close);
    await db.into(db.leaves).insert(
          LeavesCompanion.insert(
            yearId: 1,
            studentId: studentId,
            start: '2026-09-20',
            end: '2026-09-20',
            type: 0,
            createdAt: '2026-09-19T08:00:00',
          ),
        );
    await _saveOrder(db, <int>[2, 3, 4, 5, 6]);
    final Leave l = await db.select(db.leaves).getSingle();
    expect(l.fromSlot, isNull);
    expect(l.toSlot, isNull);
    expect(await _covered(db), <int>{2, 3, 4, 5, 6});
  });
}
