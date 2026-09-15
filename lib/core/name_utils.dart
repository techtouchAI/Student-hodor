/// تطبيع الأسماء العربية لكشف التكرار — منفصل عن الشاشات ليكون قابلاً للاختبار.
library;

/// تطبيع الاسم: إزالة تشكيل/تطويل/مسافات زائدة وتوحيد الهمزات لكشف التكرار.
///
/// ملاحظة: هذا مفتاح *تشابه* وليس هوية؛ الهوية المستقرة للطالب هي `personKey`
/// المولّد مرة واحدة عند الإنشاء (انظر `AppDb.makePersonKey`).
String normalizeName(String s) => s
    .replaceAll(RegExp(r'[\u064B-\u0652\u0640]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('أ', 'ا')
    .replaceAll('إ', 'ا')
    .replaceAll('آ', 'ا')
    .replaceAll('ى', 'ي')
    .replaceAll('ة', 'ه')
    .trim();
