package iq.techtouch.student_hodor

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val linkChannelName = "iq.techtouch.student_hodor.links"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // فتح روابط التواصل (يوتيوب/تيليجرام) عبر ACTION_VIEW:
        // التطبيق الخارجي (متصفح/يوتيوب/تيليجرام) هو من يتصل بالإنترنت،
        // فلا نحتاج صلاحية INTERNET ويبقى التطبيق أوفلاين كما هو مصمم.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, linkChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "openUrl") {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("BAD_ARGUMENT", "لم يُمرر رابط", null)
                        return@setMethodCallHandler
                    }
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        result.success(true)
                    } catch (e: ActivityNotFoundException) {
                        // لا يوجد تطبيق يفتح الرابط (بلا متصفح مثلاً).
                        result.success(false)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
