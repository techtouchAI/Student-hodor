package iq.techtouch.student_hodor

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * بعد إعادة تشغيل الهاتف: يعيد ترتيب تنبيهات الإقفال التلقائي من ملف
 * الجدولة الذي كتبته دارت على القرص ([ClosureAlarmScheduler.MANIFEST_NAME]).
 *
 * لا يفتح التطبيق ولا يقرأ قاعدة البيانات: الملف مصدر كافٍ لإعادة ترتيب
 * مواعيد اليوم (والموعد القادم إن وُضعت مهامته مسبقاً). أي مهمة فاتها
 * الموعد تُنفَّذ عبر الاسترداد عند تشغيل التطبيق التالي — لا تُفقد.
 */
class ClosureBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) {
            return
        }
        try {
            ClosureAlarmScheduler.rescheduleFromManifest(context)
        } catch (e: Exception) {
            // تعطّل الجدولة بعد الإقلاع لا يُفقد البيانات: الاسترداد من
            // القاعدة عند تشغيل التطبيق هو الضمانة.
            Log.w("ClosureBoot", "boot reschedule failed", e)
        }
    }
}
