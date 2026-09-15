/// تخزين صور الطلاب دائماً داخل مجلد مستندات التطبيق.
///
/// كان المسار يُؤخذ كما هو من `ImagePicker` (مجلد cache مؤقت يحذفه أندرويد)،
/// فتختفي الصور من البادجات والتقارير بلا سبب ظاهر.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PhotoStore {
  const PhotoStore._();

  static Future<Directory> _dir() async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory photos = Directory(p.join(base.path, 'photos'));
    if (!photos.existsSync()) {
      photos.createSync(recursive: true);
    }
    return photos;
  }

  /// ينسخ صورة من أي مسار مؤقت إلى المخزن الدائم ويعيد المسار الجديد.
  static Future<String?> copy(String? srcPath) async {
    if (srcPath == null || srcPath.isEmpty) {
      return null;
    }
    final File src = File(srcPath);
    if (!src.existsSync()) {
      return null;
    }
    final Directory dir = await _dir();
    if (p.dirname(src.path) == dir.path) {
      return src.path; // مخزّنة مسبقاً
    }
    final String name =
        'st-${DateTime.now().microsecondsSinceEpoch}-${p.basename(srcPath)}';
    final File dst = File(p.join(dir.path, name));
    await src.copy(dst.path);
    return dst.path;
  }

  static Future<void> deleteIfExists(String? path) async {
    if (path == null || path.isEmpty) {
      return;
    }
    final File f = File(path);
    if (f.existsSync()) {
      await f.delete();
    }
  }
}
