/// سياسة النشر في CI: حارس انحدار على ملف السير نفسه.
///
/// النشر إلى وسم `latest-apk` كان مشروطاً بـ`github.event_name != 'pull_request'`
/// فصار كل دفع إلى فرع عمل `arena/**` ينشر حزمة قيد المراجعة إلى المستخدمين
/// ويستبدل الإصدار. هذه الاختبارات تثبّت السياسة الجديدة نصّياً: النشر من
/// `main` وحده، وكل خطوة تمسّ الإصدار مقيدة بقرار واحد.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _workflow() => File('.github/workflows/build.yml').readAsStringSync();

/// كتلة خطوة واحدة من السير: من `- name: <الاسم>` حتى الخطوة التالية.
String _step(String yaml, String name) {
  final int start = yaml.indexOf('- name: $name');
  expect(start, isNot(-1), reason: 'الخطوة «$name» موجودة');
  final int next = yaml.indexOf('\n      - ', start + 1);
  return yaml.substring(start, next == -1 ? yaml.length : next);
}

void main() {
  test('قرار النشر محسوب في مكان واحد: دفع إلى main فقط', () {
    final String yaml = _workflow();
    expect(
      yaml,
      contains(
        "PUBLISH_RELEASE: \${{ github.event_name == 'push' && "
        "github.ref == 'refs/heads/main' }}",
      ),
      reason: 'شرط واحد يجمع نوع الحدث والمرجع، لا اسم فرع نصي',
    );
    // لا يعتمد على `event_name` وحده (كان يسمح بالنشر من كل الفروع).
    expect(yaml.contains("if: github.event_name != 'pull_request'"), isFalse);
  });

  test('كل خطوة تمسّ الإصدار مقيدة بـPUBLISH_RELEASE', () {
    final String yaml = _workflow();
    for (final String step in <String>[
      'Fetch previously published APK for the update gate',
      'Publish APKs to GitHub Release',
      'Commit release gate report',
    ]) {
      final String block = _step(yaml, step);
      expect(
        block,
        contains("if: env.PUBLISH_RELEASE == 'true'"),
        reason: '«$step» لا تُنفَّذ في بناء فرع عمل',
      );
    }
  });

  test('البوابة تعمل في كل بناء، لكنها تقارن بالمنشور عند النشر فقط', () {
    final String yaml = _workflow();
    final String gate = _step(yaml, 'Release gate (verify + update compatibility)');
    expect(gate, contains('verify_apk.py'), reason: 'الفحص الذاتي لا يُعطَّل');
    expect(
      gate,
      contains('if [ "\${PUBLISH_RELEASE:-false}" = "true" ]'),
      reason: '`--previous` لا يُمرَّر في بناء فرع عمل (لا مقارنة بمنشور)',
    );
    expect(
      gate.contains('if: env.PUBLISH_RELEASE'),
      isFalse,
      reason: 'البوابة نفسها تبقى إلزامية في كل تشغيل',
    );
  });

  test('نشر main لا يُلغى تلقائياً في منتصفه', () {
    final String yaml = _workflow();
    expect(
      yaml,
      contains("cancel-in-progress: \${{ github.ref != 'refs/heads/main' }}"),
      reason: 'إلغاء نشر جارٍ يترك وسم الإصدار في حالة غير معروفة',
    );
  });

  test('التشغيل اليدوي وطلبات السحب لا تُفعّل النشر', () {
    // القرار يعتمد على push + refs/heads/main، فطلب السحب (refs/pull/N/merge)
    // والتشغيل اليدوي (refs/heads/arena/**) يعطيان false حتماً.
    final String yaml = _workflow();
    expect(yaml, contains('pull_request:'));
    expect(yaml, contains('workflow_dispatch:'));
    expect(
      RegExp(r"ref == 'refs/heads/main'").allMatches(yaml).length,
      1,
      reason: 'شرط مرجع واحد فقط يقرر النشر',
    );
  });
}
