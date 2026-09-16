/// تشكيل الحروف العربية وترتيبها البصري (Bidi) لتوليد PDF صحيح.
///
/// خلفية: حزم توليد PDF في Dart ترسم النص كما هو بدون تشكيل سياقي، فتظهر
/// الحروف مقطعة. هذه الوحدة تطبق تشكيلاً سياقياً (Isolated/Final/Initial/
/// Medial) مع لام-ألف، ثم تحوّل النص لمنطق العرض البصري المناسب لسياق RTL.
/// الوحدة مغطاة باختبارات وحدة في test/arabic_shaping_test.dart.
///
/// تنبيه التشكيل: الناتج يستخدم أشكال التقديم (U+FE80..U+FEFC) بما فيها
/// **المعزولة**، لذا يشترط خطاً يغطيها كاملة (Amiri المضمّن). الخط السابق
/// كان يفتقد كل الأشكال المعزولة فكانت الحروف المفردة والطرفية تظهر مربعات.
/// وقاعدة العرض: النص المُشكّل هنا **بصري** يُرسم باتجاه LTR دائماً — لا
/// تلفّه بـ`Directionality(rtl)` في PDF وإلا طبّقت الحزمة خوارزمية Bidi فوقه
/// مرة ثانية فتخربط الترتيب.
library;

/// أشكال التقديم: [معزول، نهائي، ابتدائي، وسطي]
const Map<int, List<int>> _forms = <int, List<int>>{
  0x0621: <int>[0xFE80, 0xFE80, 0xFE80, 0xFE80],
  0x0622: <int>[0xFE81, 0xFE82, 0xFE81, 0xFE82],
  0x0623: <int>[0xFE83, 0xFE84, 0xFE83, 0xFE84],
  0x0624: <int>[0xFE85, 0xFE86, 0xFE85, 0xFE86],
  0x0625: <int>[0xFE87, 0xFE88, 0xFE87, 0xFE88],
  0x0626: <int>[0xFE89, 0xFE8A, 0xFE8B, 0xFE8C],
  0x0627: <int>[0xFE8D, 0xFE8E, 0xFE8D, 0xFE8E],
  0x0628: <int>[0xFE8F, 0xFE90, 0xFE91, 0xFE92],
  0x0629: <int>[0xFE93, 0xFE94, 0xFE93, 0xFE94],
  0x062A: <int>[0xFE95, 0xFE96, 0xFE97, 0xFE98],
  0x062B: <int>[0xFE99, 0xFE9A, 0xFE9B, 0xFE9C],
  0x062C: <int>[0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0],
  0x062D: <int>[0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4],
  0x062E: <int>[0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8],
  0x062F: <int>[0xFEA9, 0xFEAA, 0xFEA9, 0xFEAA],
  0x0630: <int>[0xFEAB, 0xFEAC, 0xFEAB, 0xFEAC],
  0x0631: <int>[0xFEAD, 0xFEAE, 0xFEAD, 0xFEAE],
  0x0632: <int>[0xFEAF, 0xFEB0, 0xFEAF, 0xFEB0],
  0x0633: <int>[0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4],
  0x0634: <int>[0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8],
  0x0635: <int>[0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC],
  0x0636: <int>[0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0],
  0x0637: <int>[0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4],
  0x0638: <int>[0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8],
  0x0639: <int>[0xFEC9, 0xFECA, 0xFECB, 0xFECC],
  0x063A: <int>[0xFECD, 0xFECE, 0xFECF, 0xFED0],
  0x0640: <int>[0x0640, 0x0640, 0x0640, 0x0640],
  0x0641: <int>[0xFED5, 0xFED6, 0xFED7, 0xFED8],
  0x0642: <int>[0xFED9, 0xFEDA, 0xFEDB, 0xFEDC],
  0x0643: <int>[0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0],
  0x0644: <int>[0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4],
  0x0645: <int>[0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8],
  0x0646: <int>[0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC],
  0x0647: <int>[0xFEED, 0xFEEE, 0xFEEF, 0xFEF0],
  0x0648: <int>[0xFEF1, 0xFEF2, 0xFEF1, 0xFEF2],
  0x0649: <int>[0xFEF3, 0xFEF4, 0xFEF3, 0xFEF4],
  0x064A: <int>[0xFEF5, 0xFEF6, 0xFEF7, 0xFEF8],
};

/// حروف لا تتصل بما بعدها (تصل من اليمين فقط).
const Set<int> _rightJoiningOnly = <int>{
  0x0622, 0x0623, 0x0625, 0x0627, 0x0629, 0x062F, 0x0630, 0x0631, 0x0632,
  0x0648, 0x0649,
};

/// لام-ألف: [معزول، نهائي] لكل نوع ألف.
const Map<int, List<int>> _lamAlef = <int, List<int>>{
  0x0622: <int>[0xFEF5, 0xFEF6],
  0x0623: <int>[0xFEF7, 0xFEF8],
  0x0625: <int>[0xFEF9, 0xFEFA],
  0x0627: <int>[0xFEFB, 0xFEFC],
};

const Set<int> _harakat = <int>{
  0x064B, 0x064C, 0x064D, 0x064E, 0x064F, 0x0650, 0x0651, 0x0652,
};

bool _isArabicLetter(int cp) => _forms.containsKey(cp);

bool _joinsNext(int cp) => _isArabicLetter(cp) && !_rightJoiningOnly.contains(cp);

/// يحذف التشكيل اختيارياً ثم يعيد تشكيل الحروف سياقيًا.
/// الناتج يبقى بالترتيب المنطقي (Logical).
///
/// التطويل (ـ U+0640) **يُحفَظ دائماً**: التقارير تستخدمه فاصلاً
/// («السادس ـ أ») وحذفه كان يترك فراغاً مزدوجاً يبدو كخلل في اللغة.
String reshapeArabic(String input, {bool deleteHarakat = true}) {
  final StringBuffer out = StringBuffer();
  final Runes runes = input.runes;
  final List<int> cps = runes.toList();
  for (int i = 0; i < cps.length; i++) {
    final int cp = cps[i];
    if (deleteHarakat && _harakat.contains(cp)) {
      continue;
    }
    if (!_isArabicLetter(cp)) {
      out.writeCharCode(cp);
      continue;
    }
    // لام-ألف
    if (cp == 0x0644 && i + 1 < cps.length && _lamAlef.containsKey(cps[i + 1])) {
      final int? prev = _prevArabic(cps, i);
      final bool joinsPrev = prev != null && _joinsNext(prev);
      out.writeCharCode(_lamAlef[cps[i + 1]]![joinsPrev ? 1 : 0]);
      i++;
      continue;
    }
    final int? prev = _prevArabic(cps, i);
    final int? next = _nextArabic(cps, i);
    final bool connectsPrev = prev != null && _joinsNext(prev);
    final bool connectsNext =
        next != null && _joinsNext(cp) && !_lamAlefConsumed(cps, i);
    final int idx = connectsPrev && connectsNext
        ? 3
        : connectsPrev
            ? 1
            : connectsNext
                ? 2
                : 0;
    out.writeCharCode(_forms[cp]![idx]);
  }
  return out.toString();
}

/// هل هذا الموضع لام سيُستهلك كligature مع ما بعدها؟
bool _lamAlefConsumed(List<int> cps, int i) =>
    cps[i] == 0x0644 && i + 1 < cps.length && _lamAlef.containsKey(cps[i + 1]);

int? _prevArabic(List<int> cps, int i) {
  for (int j = i - 1; j >= 0; j--) {
    if (_harakat.contains(cps[j]) || cps[j] == 0x0640) {
      continue;
    }
    return _isArabicLetter(cps[j]) ? cps[j] : null;
  }
  return null;
}

int? _nextArabic(List<int> cps, int i) {
  for (int j = i + 1; j < cps.length; j++) {
    if (_harakat.contains(cps[j]) || cps[j] == 0x0640) {
      continue;
    }
    return _isArabicLetter(cps[j]) ? cps[j] : null;
  }
  return null;
}

bool _isRtlCp(int cp) {
  if (_forms.containsKey(cp)) {
    return true;
  }
  if (cp >= 0xFE80 && cp <= 0xFEFC) {
    return true;
  }
  if (cp >= 0x0600 && cp <= 0x06FF) {
    return true;
  }
  return cp == 0x061B || cp == 0x061F || cp == 0x060C;
}

bool _isDigitCp(int cp) =>
    (cp >= 0x0030 && cp <= 0x0039) || (cp >= 0x0660 && cp <= 0x0669);

bool _isLatinCp(int cp) =>
    (cp >= 0x0041 && cp <= 0x005A) || (cp >= 0x0061 && cp <= 0x007A);

/// أقواس تُعكَس صورها في السياق العربي (bidi mirroring) كما تفعل كل
/// عارضات النصوص: القوس الفاتح منطقياً يظهر بصرياً بالشكل المناسب لاتجاه
/// القراءة من اليمين.
const Map<int, int> _mirrors = <int, int>{
  0x0028: 0x0029, // ( ↔ )
  0x0029: 0x0028,
  0x005B: 0x005D, // [ ↔ ]
  0x005D: 0x005B,
  0x007B: 0x007D, // { ↔ }
  0x007D: 0x007B,
  0x003C: 0x003E, // < ↔ >
  0x003E: 0x003C,
};

bool _isBracketCp(int cp) => _mirrors.containsKey(cp);

/// يحوّل نصاً مُشكّلاً (أو خاماً) إلى ترتيب العرض البصري لسياق RTL:
/// - المقاطع العربية تُعكس حرفياً.
/// - مقاطع الأرقام/اللاتينية تحتفظ بترتيبها الداخلي وتوضع بموضعها الصحيح.
/// - الأقواس في مقاطع مستقلة باتجاه الفقرة (RTL) وتُعكَس صورها دائماً.
/// - نص بلا عربية إطلاقاً يُترَك كما هو (أرقام/رموز لاتينية خالصة).
String toVisualOrder(String shaped) {
  final List<int> cps = shaped.runes.toList();
  if (cps.isEmpty || !cps.any(_isRtlCp)) {
    return shaped;
  }
  final List<List<int>> tokens = <List<int>>[];
  final List<bool> tokenRtl = <bool>[];
  List<int> current = <int>[];
  // اتجاه الفقرة RTL: أي محايد في البداية (مسافة/ترقيم) يأخذ اتجاه الفقرة
  // لا LTR — كان الافتراض السابق يقلب أمثال «(ملاحظة» في البداية.
  bool currentRtl = true;
  bool hasCurrent = false;

  void flush() {
    if (current.isNotEmpty) {
      tokens.add(current);
      tokenRtl.add(currentRtl);
      current = <int>[];
      hasCurrent = false;
    }
  }

  for (int i = 0; i < cps.length; i++) {
    final int cp = cps[i];
    if (_isBracketCp(cp)) {
      // القوس يأخذ اتجاه الفقرة (RTL) في مقطع مستقل دائماً: إلصاقه بمقطع
      // لاتيني مجاور كان يعكس أحد زوجي الأقواس دون الآخر فينكسر الزوج
      // (قوسان فاتحان بدل زوج متوازن حول خليط أرقام وعربية).
      flush();
      tokens.add(<int>[cp]);
      tokenRtl.add(true);
      continue;
    }
    final bool rtl = _isRtlCp(cp);
    // الأرقام واللاتينية مقطع LTR مستقل لا يُعكس داخلياً.
    final bool kind;
    if (_isDigitCp(cp) || _isLatinCp(cp)) {
      kind = false;
    } else if (rtl) {
      kind = true;
    } else {
      // محايد (مسافة/ترقيم): يلتحق بالمقطع الحالي أو باتجاه الفقرة.
      kind = hasCurrent ? currentRtl : true;
    }
    if (!hasCurrent) {
      currentRtl = kind;
      hasCurrent = true;
      current.add(cp);
    } else if (kind == currentRtl) {
      current.add(cp);
    } else {
      flush();
      currentRtl = kind;
      hasCurrent = true;
      current.add(cp);
    }
  }
  flush();

  final StringBuffer out = StringBuffer();
  for (int t = tokens.length - 1; t >= 0; t--) {
    if (tokenRtl[t]) {
      for (int i = tokens[t].length - 1; i >= 0; i--) {
        final int cp = tokens[t][i];
        out.writeCharCode(_mirrors[cp] ?? cp);
      }
    } else {
      for (final int cp in tokens[t]) {
        out.writeCharCode(cp);
      }
    }
  }
  return out.toString();
}

/// الشكل النهائي الجاهز للرسم في PDF: تشكيل + ترتيب بصري.
String arabicForPdf(String input) => toVisualOrder(reshapeArabic(input));
