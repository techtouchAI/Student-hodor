# تدقيق الخطة ↔ التنفيذ — Student Hodor 1.1.0

**التاريخ:** 2026-09-15 · **الفرع:** `arena/01a0a6f3-student-hodor`
**المنهج:** كل بند في `PLAN-ar.md` يُقابَل هنا بموضع الكود الذي نفّذه والاختبار الذي يثبته.
البند «✔ مُتحقَّق آلياً» يعني: analyze صفر ملاحظات + اختبار أخضر في CI + بناء APK موقّع.

---

## المرحلة 0 — بوابة التحقق

| خطة | التنفيذ | التحقق |
|---|---|---|
| 0.1 تفعيل CI على الفرع | `.github/workflows/build.yml`: `branches: [main, "arena/**"]` + `pull_request` | تشغيل 35029839911 على هذا الفرع |
| 0.2 حذف `intl` الميت + `flutter_localizations` | `pubspec.yaml`؛ `app.dart`: `locale: ar` + الثلاثة delegates | analyze ✔ |
| 0.3 الإصدار 1.1.0+2 | `pubspec.yaml` | — |

## المرحلة 1 — سلامة البيانات

| خطة | التنفيذ | التحقق |
|---|---|---|
| 1.1 تسلسل سنة فريد | `AppDb.nextSeqForYear` + `AppDb.addStudent` (معاملة واحدة: طالب+باج)؛ `YearsService.promote` يستخدمه أيضاً | `test/seq_and_badge_test.dart` (صفّان × 3 طلاب، لا تكرار تسلسل ولا رمز) |
| 1.2 personKey مولّد | `AppDb.makePersonKey`؛ الترقية تحمل المفتاح القديم | `test/seq_and_badge_test.dart` (ضمنياً) |
| 1.3 صور دائمة | `data/photo_store.dart` (نسخ/حذف)؛ `students_screen._edit` ينسخ عند الحفظ ويحذف عند الاستبدال/الحذف | analyze ✔ |
| 1.4 هجرة v2 + فهارس | `db.schemaVersion=2` + `_ensureIndexes` في onCreate/onUpgrade | `test/leave_sync_test.dart` (استعلام sqlite_master ≥6 فهارس) |
| 1.5 isOnLeave بـSQL | `db.isOnLeave` بـ`isSmallerOrEqualValue/isBiggerOrEqualValue` | `test/close_session_test.dart` (احترام الإجازة عند الإقفال) |
| 1.6 مزامنة إجازة↔حضور | `db.syncLeaveToAttendance`؛ تستدعيها `leaves_screen` إضافةً وحذفاً | `test/leave_sync_test.dart` (الاتجاهان + عدم لمس السجلات اليدوية) |
| 1.7 تحذير يوم غير دوام | `day_sheet_screen._confirmClose` يفحص `SchoolTime.isSchoolDay` ويحذّر قبل الإقفال | analyze ✔ |
| 1.8 حذف طالب/صف + بدل فاقد | `db.deleteStudent`/`deleteClass`/`reissueBadge`؛ واجهات في `students_screen`/`classes_screen`؛ `BadgeCode.make(version:)` | `test/seq_and_badge_test.dart` (بدل فاقد: إبطال+رمز مختلف+نسخة 2) |
| — علّة إضافية كشفها التدقيق | `upsertAttendance` كان `insertOnConflictUpdate` على قيد id ⇒ أي تحديث حضور يرمي UNIQUE؛ أُعيدت كتابته إدراج/تحديث صريحين على (studentId,date) | `test/leave_sync_test.dart` (تحديث حاضر→متأخر بسجل واحد) |
| — علّة إضافية | `BadgeCode.parse` كان يقصّ الجسم 16 خانة فيبتلع خانة التحقق ⇒ كل الرموز مرفوضة؛ القص الآن 14 | `test/badge_code_test.dart` (دورة make/parse + النسخة) |

## المرحلة 2 — أنماط البناء

| خطة | التنفيذ |
|---|---|
| 2.1 الإعدادات | `settings_screen`: تحميل واحد في `initState` + حالة خطأ وزر إعادة (بلا `FutureBuilder(future:_load())`) |
| 2.2 البادجات | `badges_screen`: `_specsFuture` في State + زر تحديث + معاينة حوارية |
| 2.3 تقرير الطالب | `student_report_screen`: حزمة إعدادات/عطل تُحمّل مرة (`_bundle`)؛ الطالب عبر `watchSingleOrNull` |
| 2.4 التقارير | `reports_screen`: `_ClassDayList`/`_AlertsList`_stateful بمفتاح مدخلات (`didUpdateWidget`) |
| 2.5 الإجازات | `leaves_screen`: اسم الطالب من stream طلاب مُفهرس، بلا FutureBuilder لكل صف |
| 2.6 المسح | `scan_screen`: `_noYear` برسالة بدل دوّامة؛ `errorBuilder` للكاميرا مع إعادة المحاولة |

## المرحلة 3 — التنقّل والربط

| خطة | التنفيذ |
|---|---|
| 3.1 push للتفرعات | كل drill-down في home/classes/reports/students/scan صار `context.push`؛ `go` للجذور فقط |
| 3.2 errorBuilder + مساران | `app.dart`: `_RouteErrorScreen`؛ `/student/:id`؛ `/day-sheet?class=&date=` |
| 3.3 كشف اليوم | `features/attendance/day_sheet_screen.dart`: حالات ملوّنة، تصحيح يدوي (حاضر/متأخر/إجازة/غائب/إلغاء)، فلتر «غير المسجلين»، إقفال/إعادة فتح، رابط لشاشة المسح |
| 3.4 جلسات اليوم في الرئيسة | `home_screen._TodayCard`: لكل صف مسجل/الكل + مفتوحة/مقفلة + دخول مباشر لكشف اليوم |
| 3.5 بعد التصفير | `years_screen._reset` ⇒ `context.go('/onboarding')` |

## المرحلة 4 — استكمال المواصفة

| خطة | التنفيذ |
|---|---|
| 4.1 نهاية السنة | `yearEndedProvider` + لافتة في الرئيسة + حوار بثلاثة خيارات؛ `YearsService.rolloverKeepNames` = «تصفير العدّاد مع إبقاء الأسماء» (سنة جديدة + أرشفة + نقل كل الطلاب لصفوف مطابقة ببادجات جديدة) |
| 4.2 حد الإنذار الثاني | `reports_screen._AlertsList` بعتبتين (تحذير/خطر)؛ `student_report` يحمّلهما في الحزمة |
| 4.3 حالة «متأخر» | `ScanService.lateCutoff` (بداية اليوم + دقائق السماح من الإعدادات) ⇒ مسح متأخر = late؛ والتعليم اليدوي متاح في كشف اليوم |
| 4.4 خيارات محتوى التصدير | `export_screen`: مفاتيح (جداول يومية/ملخّص/إجازات)؛ `excel_builder` أوراق ملخّص وإجازات؛ `pdf_report` صفحة ملخّص |
| 4.5 wakelock | `scan_screen`: تفعيل عند الدخول وتعطيل عند الخروج |
| 4.6 تعريب المواد | `app.dart` localizations + locale |
| 4.7 الباج حسب النموذج | `badge_widget`: ختم دائري مرسوم + guilloche + ترويسة بالختم + صف QR/Code128؛ `badge_print`: ختم دائري بحرف المدرسة وصف رموز مطابق |

## المرحلة 5 — صحة التصدير

| خطة | التنفيذ | التحقق |
|---|---|---|
| 5.1 السنة الميلادية للأشهر | `MonthKey` + `SchoolTime.monthsBetween/Keys`؛ excel/pdf/export كلها تستخدم `MonthKey` | `test/month_key_test.dart` |
| 5.2 أسماء الأوراق | `ExcelBuilder.sanitizeSheetName` (≤27 + استبدال الممنوع) + تمييز بتعدّاد | `test/month_key_test.dart` (بلا RangeError، قص، استبدال) |
| 5.3 try/catch برسائل | `export_screen._generate`، `settings_screen._backup/_restoreOrMerge` | analyze ✔ |
| 5.4 أعمدة/ورقة ملخّص | excel: غياب/إجازة/حضور/متأخر/نسبة + ورقة ملخّص؛ pdf: صفحة ملخّص | — |

## المرحلة 6 — طبقة مشتركة واختبارات

| خطة | التنفيذ |
|---|---|
| 6.1 تسميات/ألوان الحالات | `core/attendance_labels.dart` (statusName/Color/Letter/Hint) تستخدمها reports/day-sheet |
| 6.2 تطبيع الاسم | `core/name_utils.dart` |
| 6.3 اختبارات جديدة | 4 ملفات: seq_and_badge، month_key، leave_sync (+upsert وفهارس)، وتحديث badge_code |
| 6.4 توثيق | `ANALYSIS-ar.md`، `PLAN-ar.md`، هذا الملف، وتحديث `FINAL-REVIEW-ar.md` |

---

## ما لم يُنفَّذ (بشفافية) ويُترك مفتوحاً

1. تصدير الباج كصورة PNG 300dpi مباشرة (الطباعة/Mشاركة تتم عبر PDF الطباعة).
2. وجه خلفي مطبوع للباج بتعليمات الاستخدام (النموذج البصري وجه أمامي فقط).
3. بذرة عطل رسمية عراقية جاهزة (الإدارة تضيفها من الإعدادات).
4. نافذة زمنية لقبول المسح مستقلة عن «متأخر» (اعتُمد نموذج البداية+سماح الأبسط).
5. توحيد الهمزات في `normalizeName` صار أقوى من النسخة القديمة؛ أسماء مُدخلة قبل 1.1.0
   يحتفظ كل منها بـ`personKey` الخاص به فلا تتأثر المسيرات القديمة.

## نتيجة بوابة الجودة الأخيرة

- `flutter analyze --fatal-warnings --fatal-infos`: **No issues found**.
- `flutter test`: **كل الاختبارات خضراء** (29 اختباراً).
- `Build APK`: universal + split-per-abi + تحقق توقيع (CN=Student Hodor) — انظر سجل التشغيل في GitHub Actions.
