/// استيراد أسماء الطلاب من ملف نصي أو من Word: قراءة، تنظيف، معاينة.
///
/// القاعدة الحاكمة: **لا كتابة قبل معاينة**. هذه الوحدة لا تعرف قاعدة البيانات
/// ولا الواجهة؛ تُنتج [NameImportPreview] قابلة للعرض والاختبار، وحدها شاشة
/// الاستيراد تقرّر ثم تنادي `AppDb.importStudentNames` في معاملة واحدة.
///
/// الوسائط: `.txt` (UTF‑8 أو UTF‑16 بعلامة ترتيب، وارتداد إلى Windows‑1256
/// لملفات Notepad العربية القديمة) و`.docx` (فقرات وجداول). ملف `.doc` الثنائي
/// يُرفض برسالة صريحة لا بمحاولة قراءة عشوائية.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'name_utils.dart';

/// أقصى طول اسم مقبول — حد المخطط نفسه (120 محرفاً).
const int maxStudentNameLength = 120;

/// سطر تُخطّي مع سبب مفهوم للمستخدم.
class NameImportSkip {
  const NameImportSkip({
    required this.line,
    required this.raw,
    required this.reason,
  });

  /// رقم السطر/العنصر في الملف كما ظهر (يبدأ من 1).
  final int line;
  final String raw;
  final String reason;
}

/// اسم مقبول بعد التنظيف، بترتيب ظهوره في الملف.
class ImportedName {
  const ImportedName({
    required this.line,
    required this.raw,
    required this.name,
    required this.key,
  });

  final int line;
  final String raw;
  final String name;

  /// مفتاح التشابه (تطبيع + حالة أحرف) — لكشف المكرر داخل الملف وقاعدة البيانات.
  final String key;
}

/// نتيجة قراءة الملف: أسماء مقبولة + متخطّاة بأسبابها + وصف المصدر.
class NameImportPreview {
  const NameImportPreview({
    required this.names,
    required this.skipped,
    required this.source,
    this.error,
  });

  final List<ImportedName> names;
  final List<NameImportSkip> skipped;

  /// «نص — UTF‑8»، «Word — جدول (عمود الاسم 2)»… للعرض في المعاينة.
  final String source;

  /// رسالة رفض للملف كله (`null` = قراءة سليمة).
  final String? error;

  bool get ok => error == null;

  List<String> get values => <String>[for (final ImportedName n in names) n.name];

  /// عدد المتخطّين مجمّعين بالسبب — لسطر واحد في المعاينة.
  Map<String, int> get skippedByReason {
    final Map<String, int> out = <String, int>{};
    for (final NameImportSkip s in skipped) {
      out[s.reason] = (out[s.reason] ?? 0) + 1;
    }
    return out;
  }
}

/// حصيلة الاستيراد الفعلي في القاعدة (للرسالة النهائية والاختبارات).
class StudentImportOutcome {
  const StudentImportOutcome({
    required this.added,
    required this.skippedExisting,
    required this.skippedDuplicate,
    required this.skippedInvalid,
  });

  final int added;
  final int skippedExisting;
  final int skippedDuplicate;
  final int skippedInvalid;

  int get skippedTotal => skippedExisting + skippedDuplicate + skippedInvalid;

  String get summary {
    final StringBuffer b = StringBuffer('أُضيف $added طالباً');
    if (skippedExisting > 0) {
      b.write('، تُخطّي $skippedExisting موجوداً');
    }
    if (skippedDuplicate > 0) {
      b.write('، $skippedDuplicate مكرراً في الملف');
    }
    if (skippedInvalid > 0) {
      b.write('، $skippedInvalid غير صالح');
    }
    return b.toString();
  }
}

/// كلمات الترويسة التي تُتخطّى ولا تُعدّ أسماء (بعد [normalizeName]).
const Set<String> _headerLabels = <String>{
  'الاسم',
  'الاسماء',
  'اسم',
  'اسم الطالب',
  'اسم الطالبه',
  'الطالب',
  'الطالبه',
  'الاسم الثلاثي',
  'الاسم الرباعي',
  'الاسم الكامل',
  'ت',
  'م',
  'الرقم',
  'رقم',
  'رقم الطالب',
  'التسلسل',
  'تسلسل',
  'الشعبه',
  'الصف',
  'ملاحظات',
  'ملاحظه',
  'name',
  'student',
  'student name',
  'no',
  'seq',
  'id',
  '#',
};

/// هل النص ترويسة عمود؟ (يُقارن بعد التطبيع، فلا يفرّق التشكيل ولا الهمزات).
bool isHeaderLabel(String text) {
  final String key = normalizeName(text).toLowerCase();
  return key.isNotEmpty && _headerLabels.contains(key);
}

/// فكّ بايتات ملف نصي إلى نص.
///
/// الترتيب: علامة ترتيب البايتات (UTF‑8/UTF‑16)، ثم UTF‑8 الصارم، وأخيراً
/// Windows‑1256 — وهي الحالة الشائعة لملفات Notepad العربية القديمة التي
/// تظهر «رموزاً» عند قراءتها كـUTF‑8.
String decodeNameBytes(Uint8List bytes) {
  if (bytes.isEmpty) {
    return '';
  }
  final String decoded = _decodeWithBom(bytes);
  if (decoded.isNotEmpty || _hasBom(bytes)) {
    return decoded;
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return _decodeWin1256(bytes);
  }
}

bool _hasBom(Uint8List b) =>
    (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) ||
    (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) ||
    (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF);

/// يفكّ ما يحمل علامة ترتيب صريحة؛ وإلا يعيد نصاً فارغاً ليكمل المُنادي.
String _decodeWithBom(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
    return utf8.decode(b.sublist(3), allowMalformed: true);
  }
  final bool littleEndian = b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE;
  final bool bigEndian = b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF;
  if (!littleEndian && !bigEndian) {
    return '';
  }
  final StringBuffer out = StringBuffer();
  for (int i = 2; i + 1 < b.length; i += 2) {
    final int unit =
        littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1];
    out.writeCharCode(unit);
  }
  return out.toString();
}

String _decodeWin1256(Uint8List bytes) {
  final StringBuffer out = StringBuffer();
  for (final int b in bytes) {
    out.write(b < 0x80 ? String.fromCharCode(b) : _cp1256High[b - 0x80]);
  }
  return out.toString();
}

/// جدول Windows‑1256 للبايتات 0x80–0xFF (مطابق لجدول مايكروسوفت الرسمي).
const String _cp1256High = '\u20AC\u067E\u201A\u0192\u201E\u2026\u2020\u2021\u02C6\u2030\u0679\u2039\u0152\u0686\u0698\u0688\u06AF\u2018\u2019\u201C\u201D\u2022\u2013\u2014\u06A9\u2122\u0691\u203A\u0153\u200C\u200D\u06BA\u00A0\u060C\u00A2\u00A3\u00A4\u00A5\u00A6\u00A7\u00A8\u00A9\u06BE\u00AB\u00AC\u00AD\u00AE\u00AF\u00B0\u00B1\u00B2\u00B3\u00B4\u00B5\u00B6\u00B7\u00B8\u00B9\u061B\u00BB\u00BC\u00BD\u00BE\u061F\u06C1\u0621\u0622\u0623\u0624\u0625\u0626\u0627\u0628\u0629\u062A\u062B\u062C\u062D\u062E\u062F\u0630\u0631\u0632\u0633\u0634\u0635\u0636\u00D7\u0637\u0638\u0639\u063A\u0640\u0641\u0642\u0643\u00E0\u0644\u00E2\u0645\u0646\u0647\u0648\u00E7\u00E8\u00E9\u00EA\u00EB\u0649\u064A\u00EE\u00EF\u064B\u064C\u064D\u064E\u00F4\u064F\u0650\u00F7\u0651\u00F9\u0652\u00FB\u00FC\u200E\u200F\u06D2';

/// ينزع الترقيم البادئ: `1.`، `1-`، `١)`، `(3)`، `•`، `#7`، `-`.
String stripLeadingNumbering(String line) {
  String s = line.trim();
  final RegExp numbering = RegExp(
    r'^(?:[([]\s*[0-9\u0660-\u0669]{1,3}\s*[)\]]\s*'
    r'|[0-9\u0660-\u0669]{1,3}\s*[.\-–):]\s*'
    r'|[-–—•▪◦*]\s*'
    r'|#\s*[0-9\u0660-\u0669]{0,3}\s*)',
  );
  // مرتان تكفيان لحالات مثل «- 1) الاسم».
  for (int i = 0; i < 2; i++) {
    final String next = s.replaceFirst(numbering, '');
    if (next == s) {
      break;
    }
    s = next;
  }
  return s.trim();
}

/// تنظيف الاسم للتخزين: حذف التشكيل والتطويل والمحارف الصفرية وتوحيد المسافات.
///
/// لا يُغيّر الهمزات ولا التاء المربوطة: هذا نص يُعرض ويُطبع، لا مفتاح بحث.
/// (التوحيد للتشابه يقوم به [studentNameKey] عبر `normalizeName`.)
String cleanStudentName(String line) => line
    .replaceAll(RegExp(r'[\u064B-\u0652\u0640\u200C\u200D\u200E\u200F\uFEFF]'), '')
    .replaceAll(RegExp(r'[\u00A0\t]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// مفتاح تشابه الاسم: تطبيع `normalizeName` + خفض حالة الأحرف اللاتينية.
String studentNameKey(String name) => normalizeName(name).toLowerCase();

/// كلمات تبدأ بها عناوين الكشوف لا الأسماء («قائمة…»، «كشف…»، «مدرسة…»).
const Set<String> _titlePrefixes = <String>{
  'قائمه',
  'كشف',
  'سجل',
  'جدول',
  'تقرير',
  'بيان',
  'مدرسه',
  'شعبه',
  'الصف',
  'الفصل',
  'تاريخ',
  'الماده',
  'دفعه',
};

/// عبارات ترويسة كاملة (لا تُخطئ في اسم مثل «أسماء محمد»).
const List<String> _titlePhrases = <String>[
  'اسماء الطلاب',
  'اسماء الطالبات',
  'قائمه الطلاب',
  'قائمه الطالبات',
  'كشف الطلاب',
  'كشف الطالبات',
  'اسماء طلاب',
];

bool isDocumentTitle(String text) {
  final String key = normalizeName(text).toLowerCase();
  if (key.isEmpty) {
    return false;
  }
  for (final String p in _titlePhrases) {
    if (key.contains(p)) {
      return true;
    }
  }
  final String first = key.split(' ').first;
  return _titlePrefixes.contains(first) && key.split(' ').length >= 2;
}

/// هل النص اسم طالب محتمل؟ (يرفض الأسطر الرقمية وعلامات الصفحات والحقول).
bool isImportableName(String text) {
  final String s = text.trim();
  if (s.isEmpty || s.length > maxStudentNameLength) {
    return false;
  }
  final RegExp arabic = RegExp(r'[\u0621-\u064A]');
  final RegExp latin = RegExp(r'[A-Za-z]');
  if (!arabic.hasMatch(s) && !latin.hasMatch(s)) {
    return false;
  }
  // أسطر رقمية صرفة أو رموز: ليست أسماء.
  if (!RegExp(r'[\u0621-\u064A]|[A-Za-z]').hasMatch(s)) {
    return false;
  }
  if (RegExp(r'^(صفحة|صفحه|page)', caseSensitive: false).hasMatch(s)) {
    return false;
  }
  if (isDocumentTitle(s)) {
    return false;
  }
  // سطر يحمل رقماً وحرفاً واحداً فقط («1 أ») ليس اسماً.
  final int letters = RegExp(r'[\u0621-\u064A]|[A-Za-z]').allMatches(s).length;
  return letters >= 2;
}

/// سبب تخطّي سطر بعد التنظيف (`null` = مقبول).
String? skipReasonFor(String raw, {required String cleaned}) {
  if (raw.trim().isEmpty) {
    return 'سطر فارغ';
  }
  if (isHeaderLabel(cleaned)) {
    return 'ترويسة عمود';
  }
  if (isDocumentTitle(cleaned)) {
    return 'عنوان/ترويسة مستند';
  }
  if (cleaned.length > maxStudentNameLength) {
    return 'أطول من 120 محرفاً';
  }
  if (!isImportableName(cleaned)) {
    return 'ليس اسماً';
  }
  return null;
}

/// يقرأ ملفاً كاملاً بحسب امتداده ويُعيد المعاينة.
NameImportPreview parseNameFile({
  required String fileName,
  required Uint8List bytes,
}) {
  final String name = fileName.toLowerCase().trim();
  final String ext = name.contains('.') ? name.split('.').last : '';
  if (ext == 'doc') {
    return const NameImportPreview(
      names: <ImportedName>[],
      skipped: <NameImportSkip>[],
      source: 'Word قديم',
      error: 'ملف Word بصيغة .doc القديمة غير مدعوم — احفظه من Word '
          'بصيغة .docx أو .txt ثم أعد المحاولة.',
    );
  }
  if (ext == 'docx') {
    return parseDocxNames(bytes);
  }
  return parseTextNames(decodeNameBytes(bytes));
}

/// يقرأ نصاً (اسم في كل سطر) ويُعيد المعاينة.
NameImportPreview parseTextNames(String text) {
  final List<String> rawLines = text.split(RegExp(r'\r\n|\r|\n'));
  final List<_Candidate> candidates = <_Candidate>[
    for (int i = 0; i < rawLines.length; i++)
      _Candidate(line: i + 1, raw: rawLines[i]),
  ];
  return _build(candidates, source: 'نص');
}

/// يقرأ ملف Word (2007+) ويستخرج الأسماء من الجداول والفقرات بترتيبها.
NameImportPreview parseDocxNames(Uint8List bytes) {
  final String? documentXml = _docxMainDocument(bytes);
  if (documentXml == null) {
    return const NameImportPreview(
      names: <ImportedName>[],
      skipped: <NameImportSkip>[],
      source: 'Word',
      error: 'تعذر قراءة مستند Word — الملف تالف أو ليس .docx صالحاً.',
    );
  }
  final List<_Candidate> candidates = <_Candidate>[];
  final List<NameImportSkip> rejectedTables = <NameImportSkip>[];
  int line = 0;
  String? tableNote;
  for (final _Block block in _blocks(documentXml)) {
    if (block.isTable) {
      final _TablePick pick = _pickNameColumn(block.xml);
      if (pick.column == null) {
        if (pick.rows.isNotEmpty) {
          line++;
          rejectedTables.add(
            NameImportSkip(
              line: line,
              raw: 'جدول ${pick.rows.length} صفاً',
              reason: 'جدول بلا عمود اسمي',
            ),
          );
        }
        line += pick.rows.length;
        continue;
      }
      tableNote ??= 'جدول (عمود الاسم ${pick.column! + 1})';
      for (int r = 0; r < pick.rows.length; r++) {
        line++;
        final List<String> row = pick.rows[r];
        if (pick.column! >= row.length) {
          continue;
        }
        candidates.add(_Candidate(line: line, raw: row[pick.column!]));
      }
      continue;
    }
    final String text = _textOf(block.xml);
    if (text.isEmpty) {
      continue;
    }
    line++;
    candidates.add(_Candidate(line: line, raw: text));
  }
  return _build(
    candidates,
    source: tableNote == null ? 'Word (فقرات)' : 'Word — $tableNote',
    extraSkips: rejectedTables,
  );
}

/// يبني المعاينة من الأسطر الخام: تنظيف، ترويسة، تخطّي، وإسقاط المكرر.
NameImportPreview _build(
  List<_Candidate> candidates, {
  required String source,
  List<NameImportSkip> extraSkips = const <NameImportSkip>[],
}) {
  final List<ImportedName> names = <ImportedName>[];
  final List<NameImportSkip> skipped = <NameImportSkip>[...extraSkips];
  final Set<String> seen = <String>{};
  for (final _Candidate c in candidates) {
    final String stripped = stripLeadingNumbering(c.raw);
    final String cleaned = cleanStudentName(stripped);
    final String? reason = skipReasonFor(c.raw, cleaned: cleaned);
    if (reason != null) {
      skipped.add(
        NameImportSkip(line: c.line, raw: c.raw.trim(), reason: reason),
      );
      continue;
    }
    final String key = studentNameKey(cleaned);
    if (!seen.add(key)) {
      skipped.add(
        NameImportSkip(
          line: c.line,
          raw: cleaned,
          reason: 'مكرر داخل الملف',
        ),
      );
      continue;
    }
    names.add(
      ImportedName(line: c.line, raw: c.raw.trim(), name: cleaned, key: key),
    );
  }
  return NameImportPreview(names: names, skipped: skipped, source: source);
}

// ---------------------------------------------------------------------------
// Word (.docx)

class _Candidate {
  const _Candidate({required this.line, required this.raw});

  final int line;
  final String raw;
}

class _Block {
  const _Block({required this.xml, required this.isTable});

  final String xml;
  final bool isTable;
}

class _TablePick {
  const _TablePick({required this.rows, required this.column});

  final List<List<String>> rows;

  /// فهرس عمود الاسم (`null` = لا عمود اسمي في هذا الجدول).
  final int? column;
}

/// يقرأ `word/document.xml` من حاوية `.docx` بلا مكتبات إضافية.
String? _docxMainDocument(Uint8List bytes) {
  try {
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    for (final ArchiveFile f in archive.files) {
      if (f.name == 'word/document.xml') {
        final List<int>? content = f.content as List<int>?;
        if (content == null) {
          return null;
        }
        return utf8.decode(content, allowMalformed: true);
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// يقسّم جسم المستند إلى كتل: جدول أو فقرة، بالترتيب (مع مراعاة تداخل الوسوم).
Iterable<_Block> _blocks(String xml) sync* {
  int i = 0;
  while (i < xml.length) {
    final int table = _indexOfTag(xml, 'w:tbl', i);
    final int paragraph = _indexOfTag(xml, 'w:p', i);
    if (table < 0 && paragraph < 0) {
      return;
    }
    if (table >= 0 && (paragraph < 0 || table < paragraph)) {
      final int end = _endOfTag(xml, 'w:tbl', table);
      if (end < 0) {
        return;
      }
      yield _Block(xml: xml.substring(table, end), isTable: true);
      i = end;
      continue;
    }
    final int close = xml.indexOf('>', paragraph);
    if (close < 0) {
      return;
    }
    if (xml.substring(paragraph, close).endsWith('/')) {
      i = close + 1;
      continue;
    }
    final int end = _endOfTag(xml, 'w:p', paragraph);
    if (end < 0) {
      return;
    }
    yield _Block(xml: xml.substring(paragraph, end), isTable: false);
    i = end;
  }
}

/// أول موضع لوسم فتح `<tag` يليه فراغ أو `>` (حتى لا يُطابق `<w:pPr`).
int _indexOfTag(String xml, String tag, int from) {
  int i = from;
  while (true) {
    final int at = xml.indexOf('<$tag', i);
    if (at < 0) {
      return -1;
    }
    final int next = at + tag.length + 1;
    if (next >= xml.length) {
      return -1;
    }
    final String ch = xml[next];
    if (ch == '>' || ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
      return at;
    }
    i = at + 1;
  }
}

/// نهاية الوسم مع احتساب التداخل؛ `-1` إن لم يكن مغلقاً.
int _endOfTag(String xml, String tag, int start) {
  final String close = '</$tag>';
  int depth = 0;
  int i = start;
  while (i < xml.length) {
    final int at = _indexOfTag(xml, tag, i);
    final int end = xml.indexOf(close, i);
    if (end < 0) {
      return -1;
    }
    if (at >= 0 && at < end) {
      final int gt = xml.indexOf('>', at);
      if (gt < 0) {
        return -1;
      }
      if (!xml.substring(at, gt).endsWith('/')) {
        depth++;
      }
      i = gt + 1;
      continue;
    }
    depth--;
    final int after = end + close.length;
    if (depth <= 0) {
      return after;
    }
    i = after;
  }
  return -1;
}

/// نص فقرة: مجموع `<w:t>` مع مسافة بين المقاطع.
String _textOf(String xml) {
  final StringBuffer out = StringBuffer();
  for (final RegExpMatch m in _textRun.allMatches(xml)) {
    final String? t = m.group(1);
    if (t == null || t.isEmpty) {
      continue;
    }
    if (out.isNotEmpty) {
      out.write(' ');
    }
    out.write(_unescapeXml(t));
  }
  return cleanStudentName(out.toString());
}

final RegExp _textRun = RegExp(r'<w:t\b[^>]*>([\s\S]*?)</w:t>');

String _unescapeXml(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// صفوف الجدول وخلاياه (نص كل خلية).
List<List<String>> _tableRows(String tableXml) {
  final String flat = _stripNestedTables(tableXml);
  final List<List<String>> rows = <List<String>>[];
  for (final RegExpMatch r in RegExp(r'<w:tr\b[\s\S]*?</w:tr>').allMatches(flat)) {
    final String rowXml = r.group(0)!;
    final List<String> cells = <String>[
      for (final RegExpMatch c
          in RegExp(r'<w:tc\b[\s\S]*?</w:tc>').allMatches(rowXml))
        _textOf(c.group(0)!),
    ];
    if (cells.isNotEmpty) {
      rows.add(cells);
    }
  }
  return rows;
}

/// يحذف الجداول المتداخلة (جدول داخل خلية) حتى لا تُقرأ صفوفه صفوفاً للخارج.
String _stripNestedTables(String tableXml) {
  final int start = _indexOfTag(tableXml, 'w:tbl', 0);
  if (start < 0) {
    return tableXml;
  }
  final int gt = tableXml.indexOf('>', start);
  final int end = _endOfTag(tableXml, 'w:tbl', start);
  if (gt < 0 || end < 0) {
    return tableXml;
  }
  final int closing = '</w:tbl>'.length;
  final String inner = tableXml.substring(gt + 1, end - closing);
  return _removeInnerTables(inner);
}

/// يحذف أي جدول يبدأ داخل النص المعطى (بمحتواه) ويُبقي ما بينه وبين غيره.
String _removeInnerTables(String xml) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (true) {
    final int at = _indexOfTag(xml, 'w:tbl', i);
    if (at < 0) {
      out.write(xml.substring(i));
      return out.toString();
    }
    final int end = _endOfTag(xml, 'w:tbl', at);
    if (end < 0) {
      out.write(xml.substring(i));
      return out.toString();
    }
    out.write(xml.substring(i, at));
    i = end;
  }
}

/// يستدلّ على عمود الاسم: أعلى نسبة خلايا «تشبه اسماً»، مع تخطّي الترويسة.
_TablePick _pickNameColumn(String tableXml) {
  final List<List<String>> rows = _tableRows(tableXml);
  if (rows.isEmpty) {
    return const _TablePick(rows: <List<String>>[], column: null);
  }
  int columns = 0;
  for (final List<String> r in rows) {
    if (r.length > columns) {
      columns = r.length;
    }
  }
  int best = -1;
  int bestScore = 0;
  for (int c = 0; c < columns; c++) {
    int scored = 0;
    int total = 0;
    for (final List<String> r in rows) {
      if (c >= r.length) {
        continue;
      }
      final String cell = cleanStudentName(r[c]);
      if (cell.isEmpty) {
        continue;
      }
      if (isHeaderLabel(cell)) {
        continue;
      }
      total++;
      if (isImportableName(cell)) {
        scored++;
      }
    }
    if (total == 0) {
      continue;
    }
    final int score = (scored * 100) ~/ total;
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  if (best < 0 || bestScore < 50) {
    return _TablePick(rows: rows, column: null);
  }
  return _TablePick(rows: rows, column: best);
}
