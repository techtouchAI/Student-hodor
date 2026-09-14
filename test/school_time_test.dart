import 'package:flutter_test/flutter_test.dart';
import 'package:student_hodor/core/school_time.dart';

void main() {
  test('الجمعة والسبت خارج أيام الدوام الافتراضية', () {
    final DateTime friday = DateTime(2026, 9, 11);
    final DateTime sunday = DateTime(2026, 9, 13);
    expect(friday.weekday, DateTime.friday);
    expect(
      SchoolTime.isSchoolDay(
        friday,
        workWeekdays: SchoolTime.defaultWorkWeekdays,
        holidayKeys: <String>{},
      ),
      isFalse,
    );
    expect(
      SchoolTime.isSchoolDay(
        sunday,
        workWeekdays: SchoolTime.defaultWorkWeekdays,
        holidayKeys: <String>{},
      ),
      isTrue,
    );
  });

  test('العطلة تمنع اعتبار اليوم يوم دوام', () {
    final DateTime day = DateTime(2026, 9, 13);
    expect(
      SchoolTime.isSchoolDay(
        day,
        workWeekdays: SchoolTime.defaultWorkWeekdays,
        holidayKeys: <String>{SchoolTime.dateKey(day)},
      ),
      isFalse,
    );
  });

  test('keysBetween شامل الطرفين', () {
    expect(
      SchoolTime.keysBetween(DateTime(2026, 1, 1), DateTime(2026, 1, 5)).length,
      5,
    );
  });

  test('parseKey يعكس dateKey', () {
    final DateTime d = DateTime(2026, 3, 7);
    expect(SchoolTime.parseKey(SchoolTime.dateKey(d)), d);
  });
}
