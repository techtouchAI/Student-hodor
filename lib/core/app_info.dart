/// معلومات التطبيق الثابتة (بلا اعتماد على إضافات منصة قد تفشل في وضع Release).
///
/// تُرفع مع كل إصدار بموازاة `pubspec.yaml` — وجودها يضمن أن المستخدم يستطيع
/// إثبات أي إصدار يشغّل عند الإبلاغ عن عطل.
library;

class AppInfo {
  const AppInfo._();

  /// يجب أن يطابق `version` في pubspec.yaml.
  static const String version = '1.2.0+4';
  static const String name = 'حضور الطالب';
}
