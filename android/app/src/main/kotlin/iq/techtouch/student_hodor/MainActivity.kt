package iq.techtouch.student_hodor

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val linkChannelName = "iq.techtouch.student_hodor.links"
    private val backupChannelName = "iq.techtouch.student_hodor.backup"

    /** المجلد الفرعي داخل التنزيلات الذي تُحفظ فيه كل النسخ الاحتياطية. */
    private val backupFolder = "نسخة احتياطية للغيابات"

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

        // حفظ النسخة الاحتياطية الإجبارية في مجلد التنزيلات العام باسم
        // مميز (التاريخ والسبب) قبل أي عملية حذف — على أندرويد 10+ عبر
        // MediaStore بلا أي صلاحية تخزين؛ الأقدم يعيد خطأ «غير مدعوم»
        // ويتكفل جانب دارت بالعودة لمسار التطبيق الخاص.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, backupChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "saveToDownloads") {
                    val fileName = call.argument<String>("fileName")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (fileName.isNullOrBlank() || bytes == null) {
                        result.error("BAD_ARGUMENT", "اسم الملف أو البايتات مفقودة", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val saved = saveBackupToDownloads(fileName, bytes)
                        if (saved != null) {
                            result.success(saved)
                        } else {
                            result.error("UNSUPPORTED", "يتطلب أندرويد 10 أو أحدث", null)
                        }
                    } catch (e: Exception) {
                        result.error("SAVE_FAILED", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    /**
     * يكتب النسخة عبر MediaStore في «التنزيلات/نسخة احتياطية للغيابات»
     * ويعيد مساراً ظاهرياً للعرض، أو `null` إن كان النظام أقدم من 29.
     */
    private fun saveBackupToDownloads(fileName: String, bytes: ByteArray): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return null
        }
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$backupFolder"
        val name = uniqueDisplayName(collection, fileName)
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "application/zip")
            put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
        }
        val uri = contentResolver.insert(collection, values) ?: return null
        contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
            ?: return null
        return "$relativePath/$name"
    }

    /** اسم فريد: يلحق عداداً قبل الامتداد إن وُجد الاسم مسبقاً. */
    private fun uniqueDisplayName(collection: Uri, base: String): String {
        if (!displayNameExists(collection, base)) {
            return base
        }
        val dot = base.lastIndexOf('.')
        val stem = if (dot > 0) base.substring(0, dot) else base
        val ext = if (dot > 0) base.substring(dot) else ""
        var i = 2
        while (true) {
            val candidate = "$stem-$i$ext"
            if (!displayNameExists(collection, candidate)) {
                return candidate
            }
            i++
        }
    }

    private fun displayNameExists(collection: Uri, name: String): Boolean {
        val cursor = contentResolver.query(
            collection,
            null,
            "${MediaStore.Downloads.DISPLAY_NAME}=?",
            arrayOf(name),
            null,
        )
        return cursor?.use { it.count > 0 } ?: false
    }
}
