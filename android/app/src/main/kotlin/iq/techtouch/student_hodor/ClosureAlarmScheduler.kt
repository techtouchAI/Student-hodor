package iq.techtouch.student_hodor

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * جدولة الإقفال التلقائي عبر AlarmManager.
 *
 * التنبيه يُعيد إطلاق التطبيق في موعد نهاية الحصة؛ تنفيذ الإقفال نفسه
 * يجري في طبقة دارت (الاسترداد عند التشغيل) — فالتطبيق المُغلق يُنفّذ
 * المهمات المتأخرة فور إقلاعه، ولا تعتمد العملية على بقاء الواجهة مفتوحة.
 *
 * الدقة مقابل الضمان:
 * - [AlarmManager.setExactAndAllowWhileIdle] عند السماح (أندرويد 12+ يطلب
 *   SCHEDULE_EXACT_ALARM): يصل في الموعد تقريباً.
 * - إن رُفضت الصلاحية أو منعها النظام، يُسقَط إلى [AlarmManager.setAndAllowWhileIdle]
 *   (تنبيه غير دقيق): لا ضمان بالدقيقة، لكنه يبقى خارج وضع توفير الطاقة
 *   قدر الإمكان. الاسترداد عند تشغيل التطبيق هو الضمانة الأساسية في كل
 *   الحالات، فلا تُفقد المهام حتى لو منع أندرويد التنبيه برمته.
 */
object ClosureAlarmScheduler {

    const val ACTION = "iq.techtouch.student_hodor.action.RUN_CLOSURE"
    const val MANIFEST_NAME = "closure_schedule.json"

    private const val PREFS_NAME = "closure_alarms"
    private const val KEY_CODES = "armed_codes"
    private const val TAG = "ClosureAlarm"

    /** مهمة جدولة واحدة كما تصل من دارت. */
    data class ArmedTask(val id: Int, val date: String, val time: String)

    /**
     * يُرتب تنبيهات [tasks]: يلغي كل ما رُتب سابقاً (حتى لا تتراك التنبيهات
     * بعد تغيير الجدول)، ثم يُرتّب الجديد. التنبيهات ذات الموعد الحاضر أو
     * الماضي تُتخطى هنا — الاسترداد عند تشغيل التطبيق ينفّذها.
     */
    fun schedule(context: Context, tasks: List<ArmedTask>) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val prefs = prefs(context)

        for (code in armedCodes(prefs)) {
            am.cancel(pendingIntentFor(context, code))
        }
        prefs.edit().remove(KEY_CODES).apply()

        if (tasks.isEmpty()) return

        val now = System.currentTimeMillis()
        val codes = mutableSetOf<String>()
        for (task in tasks) {
            val calendar = calendarFor(task.date, task.time) ?: continue
            if (calendar.timeInMillis <= now) continue // فات: الاسترداد يغطيه.
            val code = task.id.toString()
            val trigger = calendar.timeInMillis
            val pi = pendingIntentFor(context, code)
            if (canScheduleExact(am)) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
            }
            codes.add(code)
        }
        prefs.edit().putStringSet(KEY_CODES, codes).apply()
        Log.i(TAG, "scheduled ${codes.size} closure alarm(s)")
    }

    /** إلغاء كل التنبيهات المرتبة. */
    fun cancelAll(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val prefs = prefs(context)
        for (code in armedCodes(prefs)) {
            am.cancel(pendingIntentFor(context, code))
        }
        prefs.edit().remove(KEY_CODES).apply()
    }

    /**
     * يعيد ترتيب التنبيهات بعد إعادة تشغيل الهاتف من ملف الجدولة الذي
     * كتبته دارت على القرص: لا حاجة لفتح التطبيق، والاستيراد يغطي أي
     * مهمة فاتها الموعد (تُنفَّذ عند تشغيل التطبيق التالي).
     */
    fun rescheduleFromManifest(context: Context) {
        try {
            val file = File(context.filesDir, MANIFEST_NAME)
            if (!file.exists()) return
            val today = todayKey()
            val tasks = mutableListOf<ArmedTask>()
            val arr = org.json.JSONArray(file.readText())
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val date = o.optString("date")
                val time = o.optString("time")
                val id = o.optInt("id")
                if (date.isEmpty() || time.isEmpty()) continue
                // المهام التي فات موعدها لا يُعاد ترتيبها: الاسترداد عند
                // تشغيل التطبيق ينفّذها.
                if (date < today) continue
                tasks.add(ArmedTask(id, date, time))
            }
            schedule(context, tasks)
        } catch (e: Exception) {
            // تعطّل الجدولة بعد الإقلاع لا يُفقد البيانات: الاسترداد من
            // القاعدة عند تشغيل التطبيق هو الضمانة.
            Log.w(TAG, "reschedule after boot failed", e)
        }
    }

    private fun canScheduleExact(am: AlarmManager): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.canScheduleExactAlarms()
        } else {
            true
        }

    private fun armedCodes(prefs: SharedPreferences): Set<String> =
        prefs.getStringSet(KEY_CODES, emptySet()) ?: emptySet()

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /**
     * بِداية إطلاق التطبيق عند بلوغ الموعد: لا يحمل بيانات، فدارت تُنفّذ
     * الاسترداد (ويُغلق الإقفال بذرّية) بمجرد إقلاع التطبيق.
     */
    private fun pendingIntentFor(context: Context, code: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = ACTION
            putExtra("code", code)
        }
        return PendingIntent.getActivity(
            context,
            code.toIntOrNull() ?: 0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /** يبني لحظة [date] (`yyyy-MM-dd`) عند [time] (`HH:mm`) بالتوقيت المحلي. */
    private fun calendarFor(date: String, time: String): Calendar? {
        val dateFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val timeFormat = SimpleDateFormat("HH:mm", Locale.US)
        return try {
            val d: Date = dateFormat.parse(date) ?: return null
            val t: Date = timeFormat.parse(time) ?: return null
            val calendar = Calendar.getInstance().apply {
                clear()
                set(d.year + 1900, d.month, d.date, t.hours, t.minutes, 0)
                set(Calendar.MILLISECOND, 0)
            }
            calendar
        } catch (e: Exception) {
            null
        }
    }

    private fun todayKey(): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
}
