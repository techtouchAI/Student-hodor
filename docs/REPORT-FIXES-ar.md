# تقرير تنفيذ إصلاحات المراجعة (PR #13)

**التزام الشيفرة النهائي المُتحقَّق منه:** `b97868c` على فرع
`arena/74dbb144-student-hodor` — كل البوابات خضراء عليه في التشغيل نفسه.
**وبعده** `7b14d89` (هذا التقرير وملفاته التوثيقية فقط) — أخضر أيضاً.

**ما لم يُفعل بقرار منك:** لم يُدمج طلب السحب، ولم يُنشر إصدار، ولم يُحذف أي
فرع. المطلوب موافقتك قبل أي منها.

---

## 1. جدول الحالة

| البند | الحالة | الدليل التنفيذي |
|---|---|---|
| **R1** نطاق الإجازة عند حذف/إعادة ترتيب الحصص | ✅ | `saveLessons` يترجم النطاق **بالمعرّفات** داخل المعاملة نفسها، ويرفض الترتيب غير القابل للتمثيل بـ`LeaveScopeConflictException`؛ `isOnLeave` و`syncLeaveToAttendance` و`closeSession` تتفق مع السجل المادّي — `test/lesson_scope_test.dart` (7) |
| **R2** تمييز غياب الحصة من غياب اليوم | ✅ | مصدر واحد `describeDay/DayPresence`: «غياب كامل» فقط عند غياب كل حصص الجدول، وإلا «غياب جزئي — غاب عن حصة/حصتين/N»؛ لون باهت للجزئي في الشاشة وExcel وPDF، والأحمر للكامل فقط؛ `absentDays` بقي يومياً — `test/partial_absence_test.dart` (6) + `test/student_record_test.dart` |
| **R3** تنبيهات السنة المحذوفة | ✅ | `deleteYear` يحذف تنبيهات **السنة نفسها** داخل معاملة واحدة قبل الطلاب — `test/year_delete_test.dart` (تنبيهان في سنتين، الباقي سليم) |
| **R4** المفاتيح الأجنبية | ✅ | `PRAGMA foreign_keys = ON` في `beforeOpen` + معالجة ما كان يعتمد على غيابه: الدمج يتخطّى الأسطر اليتيمة ويعدّها، `deleteClass` يرفض صفاً فيه طلاب (منع حذف متسلسل صامت)، وترتيب الحذف صريح في `resetAll`/`deleteYear` — `test/backup_legacy_test.dart` + `test/migration_v6_test.dart` (`PRAGMA foreign_key_check` فارغ) |
| **R5** استعلام التنبيهات الساخن | ✅ | استعلام تجميعي واحد بدل استعلام لكل طالب — `test/notifications_test.dart` و`test/early_alerts_test.dart` خضراوان بلا تغيير توقّعات |
| **R6** فحص استخدام الحصة | ✅ | فهرسان على العمود وحده (`idx_attendance_lesson_only`، `idx_sessions_lesson_only`) — إنشاء بـ`IF NOT EXISTS` عند الفتح (لا هجرة ولا تغيير مخطط) |
| **R7** مصدر واحد لحروف الحالة | ✅ | `lessonCompactMarks`/`statusLetter`/`StatusHex` في `attendance_labels.dart`؛ حُذفت نسختا PDF المكررتان |
| **R8** تكرار `scan_events` عند الدمج | ✅ | بصمة (جلسة + رمز + وقت) تمنع التضاعف — `test/backup_legacy_test.dart` |
| **R9** ذرّية إقفال/إعادة فتح اليوم | ✅ | `closeDaySessions` و`reopenDaySessions` كل منهما معاملة واحدة، وشاشة كشف اليوم تستخدمهما — `test/close_day_test.dart` (اختبار نجاح + اختبار ارتداد لكل منهما) |
| **R10** تسمية الحصة في التصدير | ✅ | `AppDb.windowOf(lesson).displayName` في Excel وPDF (لا تكرار لمنطق الاسم) |
| **R11** «أيام الغياب» عبر الصفوف | ✅ | الوسم صار «أيام فيها غياب (مشتركة)» بلا مسّ التعريف العددي |
| **T1** نسخ احتياطي ودمج (v2/v3) | ✅ | نسخة v2 بلا `lessons` تُزرع افتراضياً وكل سطر إلى الحصة الأولى بـ`arrival_time` فارغ؛ نسخة v3 تعود بالحصص ونطاقات الإجازات؛ الدمج لا يضاعف — `test/backup_legacy_test.dart` (5) |
| **T2** إقفال اليوم بست حصص | ✅ | 17 سطراً مولّداً من 18 موضعاً، 6 جلسات مقفلة، لا تكرار عند إعادة الإقفال، الإجازة لا تُمسّ، والسطر اليدوي يبقى — `test/close_day_test.dart` |
| **T3** تكامل الهجرة 5⇒6 | ✅ | `foreign_key_check` فارغ وبقاء `scan_events.session_id` — `test/migration_v6_test.dart` |
| **استيراد الأسماء** (الملحق أ) | ✅ | `docs/NAME-IMPORT-ar.md` + `test/name_import_test.dart` (10) |

---

## 2. الملفات المعدّلة ولماذا

| الملف | السبب |
|---|---|
| `lib/data/db.dart` | R1 (`_translateLeaveScopes` + `LeaveScopeConflictException`)، R9 (`reopenDaySessions` + معاملات الإقفال)، R4 (`beforeOpen` فKeys + ترتيب الحذف + حارس `deleteClass`)، R6 (فهارس العمود)، `importStudentNames` + `_insertStudent` |
| `lib/core/attendance_labels.dart` | R2: `DayAbsence`/`DayPresence`/`describeDay`/`dayStatusColor`/`arabicLessonCount` (مصدر واحد للنص واللون) |
| `lib/core/name_import.dart` *(جديد)* | قراءة TXT (UTF‑8/UTF‑16/Windows‑1256) وDOCX (فقرات/جداول)، ترويسة، عمود الاسم، تطبيع، منع تكرار — بلا قاعدة بيانات |
| `lib/features/students/import_names_screen.dart` *(جديد)* | معاينة + تأكيد ثم كتابة واحدة (لا كتابة قبل التأكيد) |
| `lib/features/students/students_screen.dart` | مدخل الاستيراد في شريط الصف |
| `lib/data/backup_service.dart` | T1/R8/R4: قيم افتراضية مزدوجة الصيغة للمفاتيح، إسقاط الحصة المفقودة على الأولى، تخطّي الأسطر اليتيمة وعدّها، منع تكرار أحداث المسح، وتفادي تعارض معرّفات التدقيق عند الاسترجاع |
| `lib/data/reports_service.dart` | R5: تجميع التنبيهات باستعلام واحد |
| `lib/data/years_service.dart` | R3: حذف تنبيهات السنة المحذوفة وحدها |
| `lib/features/export/{excel_builder,pdf_report,student_record_pdf}.dart` | R2/R7/R10/R11: تسمية الغياب الجزئي وألوانه، مصدر موحّد للحروف، اسم الحصة، وسم «أيام فيها غياب» |
| `lib/features/reports/student_report_screen.dart` | R2: لون اليوم وتلميحه من `describeDay`، ومفتاح الألوان صار يفصل الجزئي عن الكامل |
| `lib/features/attendance/day_sheet_screen.dart` | R9: «إعادة فتح كل الحصص» عبر `reopenDaySessions` |
| `lib/features/lessons/lessons_screen.dart` | إظهار سبب رفض إعادة الترتيب (`LeaveScopeConflictException`) بدل فشل عام |
| `lib/features/settings/settings_screen.dart` | إظهار عدد الأسطر المتخطّاة في الدمج |
| `.github/workflows/verify.yml` | تقرير الفشل صار يشمل كتل الاختبارات الفاشلة كاملة (تشخيص فقط، بلا أثر على التطبيق) |
| `docs/{REVIEW-FIXES-ar,NAME-IMPORT-ar,REPORT-FIXES-ar}.md` | توثيق القواعد والأدلة |

**لم يتغيّر:** `schemaVersion` (=6)، صيغة النسخ الاحتياطي (=3)، توقيعات
`ReportsService`/`AppDb` العامة (أُضيف `reopenDaySessions` و`importStudentNames`
و`_insertStudent` خاص داخلي)، ولا سلوك قائم إلا ما كان خطأً مثبتاً.

---

## 3. الاختبارات

**الحصيلة:** 155 اختباراً في 29 ملفاً، كلها خضراء على `b97868c`.

| الملف الجديد | العدد | يغطي |
|---|---|---|
| `test/lesson_scope_test.dart` | 7 | R1: حذف قبل/داخل/بعد النطاق، إعادة الترتيب، رفض التفريق مع ارتداد كامل، تطابق `isOnLeave` مع السجلات وإقفال الحصة داخل/خارج النطاق، إجازة «كل الحصص» |
| `test/close_day_test.dart` | 3 | T2/R9: ست حصص وحالات مختلطة، منع التكرار، ارتداد الإقفال وإعادة الفتح |
| `test/backup_legacy_test.dart` | 5 | T1/R4/R8: استعادة v2، استعادة v3، دمج حصتين في يوم واحد ومنع دمج الحصة نفسها، حصة مفقودة/طالب مفقود، منع تضاعف أحداث المسح |
| `test/partial_absence_test.dart` | 6 | R2: نصوص اليوم وألوانه، النص العربي للعدد، ثبات `absentDays` |
| `test/name_import_test.dart` | 10 | الملحق أ: TXT/DOCX، الترويسة، عمود الاسم، التطبيع، التكرار، الكتابة الذرّية والسياق |
| `test/migration_v6_test.dart` (معدّل) | +1 تأكيد | T3: `foreign_key_check` وبقاء ربط أحداث المسح |
| `test/student_record_test.dart` (معدّل) | تعبير واحد | «غياب جزئي — غاب عن حصة واحدة» بدل «غائب» لغياب حصة |
| `test/year_delete_test.dart` (معدّل) | +3 تأكيدات | R3: تنبيهات السنة المحذوفة وحدها |

---

## 4. نتائج البوابات (على الالتزام نفسه)

| الخطوة | النتيجة |
|---|---|
| `flutter pub get` | ✅ |
| `dart run build_runner build` | ✅ 159 مخرجاً |
| `flutter analyze --fatal-warnings --fatal-infos` | ✅ «No issues found» |
| `flutter test` | ✅ 155/155 |
| `flutter build apk --release` (+ splits) | ✅ + بوابة الإصدار |

---

## 5. روابط التشغيل والالتزام

* verify (Analyze & Test): <https://github.com/techtouchAI/Student-hodor/actions/runs/41147949397>
* build-apk: <https://github.com/techtouchAI/Student-hodor/actions/runs/41147949394>
* الالتزام الأخير للشيفرة: **`b97868c`** — «style(import): const في طول وسم إغلاق الجدول»
* تشغيل التوثيق (`7b14d89`): verify
  <https://github.com/techtouchAI/Student-hodor/actions/runs/41148922183> —
  build-apk <https://github.com/techtouchAI/Student-hodor/actions/runs/41148922176>
* طلب السحب: #13 (مفتوح، بلا دمج).

---

## 6. أمان البيانات القديمة

* **الترقية 5⇒6** مُختبرة على قاعدة إصدار 5 حقيقية على القرص: لا صف مفقود،
  كل سطر قديم على الحصة الأولى، `arrival_time` كما هو، والتفرّد القديم
  (يوم واحد) يفسح لتفرّد (يوم + حصة) بلا فقدان.
* **المفاتيح الأجنبية** مفعّلة الآن؛ التكامل مُتحقَّق بـ`PRAGMA foreign_key_check`
  بعد الترقية. الأسطر اليتيمة في الدمج **تُتخطّى وتُعدّ** بدل إسقاط الدمج كله.
* **النسخ الاحتياطي**: صيغة 3 كما هي، والتوافق مع 1/2 مُختبر (بيان بلا `lessons`
  وبلا أعمدة الحصص/وقت الوصول/نطاق الإجازة).
* **الإجازات**: لا تُحذف ولا يُنقَّص نطاقها؛ الترجمة تُحفظ أو تُرفض العملية.
* **السجلات التاريخية**: مربوطة بمعرّف الحصة لا برقمها، فلا يمسّها إعادة الترقيم.

---

## 7. جاهزية استيراد الأسماء

منفّذ بالكامل حسب الملحق أ: `.txt` (UTF‑8/UTF‑16/Windows‑1256) و`.docx`
(فقرات وجداول)، رفض `.doc` برسالة، نزع الترقيم، تخطّي الترويسة **والعنوان**،
استدلال عمود الاسم، التطبيع، إسقاط المكرر، معاينة قبل أي كتابة، ثم كتابة
واحدة في معاملة واحدة إلى الصف والشعبة المفتوحين مع حفظ الترتيب (`seq`).

**حدود معروفة:**
1. `_lessonOf`/`_withDefaults` خاصّان (`private`) فدليلهما غير مباشر عبر
   اختبارات الدمج والاستعادة.
2. شاشة الاستيراد نفسها بلا اختبار واجهة (تعتمد على منتقي ملفات المنصّة)؛
   منطق القراءة والتطبيع والكتابة مغطّى كاملاً في `test/name_import_test.dart`.
3. الجداول المتداخلة داخل خلية تُقرأ كخلية فارغة (لا تُفسد الاستيراد).
