/// فتح روابط خارجية (متصفح/يوتيوب/تيليجرام) عبر قناة منصة صغيرة مسجّلة في
/// `MainActivity` (انظر `android/app/src/main/kotlin/.../MainActivity.kt`).
///
/// لا اعتمادية جديدة ولا صلاحية `INTERNET`: النظام يسلّم الرابط لتطبيق
/// خارجي (متصفح أو تطبيق يوتيوب/تيليجرام) هو من يتصل بالشبكة، فيبقى
/// التطبيق نفسه أوفلاين كما يقتضي تصميمه (انظر AndroidManifest).
library;

import 'package:flutter/services.dart';

class AppLinks {
  AppLinks._();

  static const MethodChannel _channel =
      MethodChannel('iq.techtouch.student_hodor.links');

  /// يفتح [url] في تطبيق خارجي. يعيد `false` إن لم يتوفر تطبيق يفتح
  /// الرابط (يبقى الرابط نفسه معروضاً في الواجهة فيمكن نسخه يدوياً).
  static Future<bool> open(String url) async {
    try {
      final Object? ok = await _channel.invokeMethod<bool>(
        'openUrl',
        <String, Object>{'url': url},
      );
      return ok == true;
    } on PlatformException catch (_) {
      return false;
    }
  }
}
