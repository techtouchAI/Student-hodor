/// الإعدادات: مدرسة/مدير/أيام الدوام/هجري/حدود الإنذار/نافذة التأخر/PIN/
/// عطل/تنبيهات (صلاحية وشبكة)/نسخ احتياطي واستعادة كاملة.
///
/// الاستعادة **استبدال** لا دمج: تُفحص النسخة أولاً، ثم يُطلب تأكيد صريح، ثم
/// تُحفظ نسخة أمان من البيانات الحالية، ثم تُستبدل البيانات في معاملة واحدة.
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/local_notifications.dart';
import '../../core/school_time.dart';
import '../../data/backup_service.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../features/about/about_screen.dart';
import '../../features/lessons/lessons_screen.dart';
import '../../state/providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsState();
}

class _SettingsState extends ConsumerState<SettingsScreen> {
  final TextEditingController _school = TextEditingController();
  final TextEditingController _director = TextEditingController();
  final TextEditingController _t1 = TextEditingController(text: '10');
  final TextEditingController _t2 = TextEditingController(text: '15');
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _dayStart = TextEditingController(text: '08:00');
  final TextEditingController _lateAfter = TextEditingController(text: '15');
  // نسخة قابلة للتعديل: المجموعة الافتراضية const ولا تقبل الإضافة.
  Set<int> _weekdays = <int>{...SchoolTime.defaultWorkWeekdays};
  bool _hijri = true;
  /// إشعارات النظام (خارج التطبيق) — مفتوحة افتراضيًا.
  bool _systemNotif = true;
  /// حالة صلاحية إشعارات النظام على الجهاز (تُحدَّث حيًّا).
  bool _permGranted = false;
  String _permLabel = '…';
  bool _loaded = false;
  String? _loadError;

  /// عملية استعادة جارية (اختيار ملف/تأكيد/استبدال). حارس واحد يمنع:
  /// نقرة مكرّرة، نافذتي تأكيد، استعادتين متزامنتين، والخروج من الشاشة أثناء
  /// الاستبدال (`PopScope` أدناه).
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _school.dispose();
    _director.dispose();
    _t1.dispose();
    _t2.dispose();
    _pin.dispose();
    _dayStart.dispose();
    _lateAfter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final Map<String, String> s =
          await ref.read(dbProvider).effectiveSettings();
      if (!mounted) {
        return;
      }
      setState(() {
        _school.text = s['school_name'] ?? '';
        _director.text = s['director_name'] ?? '';
        _t1.text = s['alert_threshold_1'] ?? '10';
        _t2.text = s['alert_threshold_2'] ?? '15';
        _pin.text = s['pin'] ?? '';
        _dayStart.text = s['day_start'] ?? '08:00';
        _lateAfter.text = s['late_after_minutes'] ?? '15';
        _systemNotif = s['system_notifications_enabled'] != '0';
        _hijri = s['show_hijri'] == '1';
        _weekdays = <int>{
          for (final String w in (s['work_weekdays'] ?? '7,1,2,3,4').split(','))
            int.tryParse(w) ?? 0,
        };
        _loaded = true;
        _loadError = null;
      });
      unawaited(_refreshPermissionState());
    } catch (e) {
      if (mounted) {
        setState(() => _loadError = '$e');
      }
    }
  }

  /// حالة صلاحية إشعارات النظام على هذا الجهاز (نداء حي — لا يخزَّن
  /// كحقيقة، ويُخزَّن فقط كسجل حالة).
  Future<void> _refreshPermissionState() async {
    final bool ok = await LocalNotifications.areNotificationsEnabled();
    if (!mounted) {
      return;
    }
    setState(() {
      _permGranted = ok;
      _permLabel = ok
          ? 'مسموح — ستظهر إشعارات منبثقة على هاتفك'
          : 'غير مسموح — لن تظهر إشعارات منبثقة';
    });
    unawaited(
      ref
          .read(dbProvider)
          .setSetting('notifications_permission_state', ok ? 'granted' : 'denied'),
    );
  }

  Future<void> _requestPermission() async {
    try {
      final bool granted = await LocalNotifications.requestPermission();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              granted
                  ? 'فُعّلت الإشعارات'
                  : 'لم تُمنح الصلاحية — جرّب من «إعدادات النظام»',
            ),
          ),
        );
      }
    } catch (e, st) {
      AppErrorLog.instance.record(
        e,
        st,
        where: 'settings:notification-permission',
      );
    }
    await _refreshPermissionState();
  }

  /// صفحة النظام لإشعارات التطبيق (أندرويد 13+: مفتاح الصلاحية نفسه).
  Future<void> _openNotificationSettings() async {
    try {
      await LocalNotifications.openNotificationSettings();
    } catch (e, st) {
      AppErrorLog.instance.record(
        e,
        st,
        where: 'settings:open-notification-settings',
      );
    }
    await _refreshPermissionState();
  }

  Future<void> _about() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const AboutScreen(),
      ),
    );
  }

  Future<void> _save() async {
    final AppDb db = ref.read(dbProvider);
    try {
      await _saveAll(db);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('حُفظت الإعدادات')));
      }
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'settings:save');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر الحفظ: $e')));
      }
    }
  }

  Future<void> _saveAll(AppDb db) async {
    await db.setSetting('school_name', _school.text.trim());
    await db.setSetting('director_name', _director.text.trim());
    await db.setSetting('alert_threshold_1', _t1.text.trim());
    await db.setSetting('alert_threshold_2', _t2.text.trim());
      await db.setSetting('pin', _pin.text.trim());
      await db.setSetting(
        'system_notifications_enabled',
        _systemNotif ? '1' : '0',
      );
      await db.setSetting('day_start', _dayStart.text.trim());
      await db.setSetting('late_after_minutes', _lateAfter.text.trim());
    await db.setSetting('show_hijri', _hijri ? '1' : '0');
    await db.setSetting('work_weekdays', _weekdays.join(','));
    await db.logAudit('settings_save', '');
    ref.invalidate(settingsProvider);
    ref.invalidate(effectiveSettingsProvider);
  }

  Future<void> _lessons() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const LessonsScreen(),
      ),
    );
    // الجدول قد تغيّر: لا تُعرض قيم قديمة في بقية الشاشة أو في التقارير.
    ref.invalidate(effectiveSettingsProvider);
  }

  Future<void> _holidays() async {
    final AppDb db = ref.read(dbProvider);
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (BuildContext context) => _HolidaysEditor(db: db)),
    );
  }

  Future<void> _backup() async {
    if (_restoring) {
      return; // لا نسخ متزامن مع استعادة تعيد كتابة القاعدة.
    }
    try {
      final String path = await BackupService(ref.read(dbProvider)).exportFile();
      await SharePlus.instance.share(
        ShareParams(files: <XFile>[XFile(path, mimeType: 'application/zip')]),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر النسخ الاحتياطي: $e')));
      }
    }
  }

  /// استعادة كاملة: بيانات النسخة تحلّ محل بيانات التطبيق كلها (لا دمج).
  ///
  /// التسلسل الإلزامي:
  /// 1. اختيار الملف (إلغاء المنتقي لا يغيّر شيئاً).
  /// 2. فحص الصيغة والبنية والمراجع **بلا أي كتابة** ([BackupService.inspect]).
  /// 3. تأكيد صريح يعرض معلومات النسخة وتحذير الاستبدال.
  /// 4. نسخة أمان من البيانات الحالية (فشلها يُلغي الاستعادة).
  /// 5. استبدال ذرّي + فحص سلامة المراجع داخل المعاملة.
  /// 6. تحديث المزوّدات وحقول الشاشة، ثم رسالة نجاح/فشل دقيقة.
  Future<void> _restore() async {
    if (_restoring) {
      return;
    }
    setState(() => _restoring = true);
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['zip', 'json'],
      );
      final PlatformFile? file = picked.isEmpty ? null : picked.single;
      final String? path = file?.path;
      if (path == null) {
        return; // إلغاء منتقي الملفات: لم يُقرأ شيء ولم يُكتب شيء.
      }
      final String fileName =
          (file != null && file.name.isNotEmpty) ? file.name : p.basename(path);
      final Uint8List bytes = await File(path).readAsBytes();
      final AppDb db = ref.read(dbProvider);
      final BackupService svc = BackupService(db);

      // لا تأكيد على ملف لم يُفحص: التحقق أولاً ثم الموافقة.
      final BackupInfo info = await svc.inspect(bytes);
      if (!mounted) {
        return;
      }
      final bool confirmed = await _confirmRestore(info, fileName);
      if (!confirmed) {
        return; // إلغاء صريح: لا كتابة ولا حذف.
      }

      final String safetyCopy =
          await svc.exportSafetyCopy(reason: 'قبل الاستعادة');
      await svc.restoreFull(bytes);

      // لا بيانات قديمة في المزوّدات أو حقول الشاشة بعد الاستبدال.
      ref.invalidate(settingsProvider);
      ref.invalidate(effectiveSettingsProvider);
      ref.invalidate(currentYearProvider);
      ref.invalidate(yearEndedProvider);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تمت استعادة النسخة واستبدال البيانات. '
              'نسخة أمان من بياناتك السابقة: ${p.basename(safetyCopy)}',
            ),
          ),
        );
      }
    } catch (e, st) {
      AppErrorLog.instance.record(e, st, where: 'settings:restore');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_restoreError(e))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _restoring = false);
      }
    }
  }

  /// نافذة تأكيد الاستبدال: معلومات النسخة + تحذير صريح + تسميات لا تلتبس.
  ///
  /// `barrierDismissible: false` و`PopScope(canPop: false)` يمنعان إغلاقها
  /// بالرجوع أو بالنقر خارجها، و`answered` يمنع تنفيذ نقرتين متتاليتين على
  /// الزر نفسه (النقرة الثانية كانت ستُغلق شاشة الإعدادات نفسها).
  Future<bool> _confirmRestore(BackupInfo info, String fileName) async {
    bool answered = false;
    final bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('استعادة كاملة — استبدال البيانات الحالية'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('الملف: $fileName'),
                if (info.createdAt != null)
                  Text('تاريخ النسخة: ${_stamp(info.createdAt!)}'),
                Text('إصدار الصيغة: ${info.version}'),
                Text('محتوى النسخة: ${_restoreContents(info)}'),
                if (info.legacyLessons) ...<Widget>[
                  const SizedBox(height: 8),
                  const Text(
                    'ملاحظة: نسخة قديمة بلا جدول حصص؛ ستُزرع الحصص الافتراضية '
                    'وتُسند سجلاتها القديمة إلى الحصة الأولى (تعريف الترحيل).',
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'ستُستبدل بياناتك الحالية بالكامل: الطلاب والصفوف والسنوات '
                  'والحضور والإجازات والتنبيهات والإعدادات وجدول الحصص والصور.',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'ليست إضافة ولا دمجاً: أي بيانات حالية غير موجودة في النسخة '
                  'ستُفقد.',
                ),
                const SizedBox(height: 8),
                const Text(
                  '«إلغاء» يترك بياناتك الحالية كما هي دون أي تغيير. وقبل '
                  'الاستبدال تُحفظ نسخة أمان من بياناتك الحالية تلقائياً.',
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                if (answered) {
                  return;
                }
                answered = true;
                Navigator.pop(ctx, false);
              },
              child: const Text('إلغاء'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              onPressed: () {
                if (answered) {
                  return;
                }
                answered = true;
                Navigator.pop(ctx, true);
              },
              child: const Text('استعادة النسخة واستبدال البيانات الحالية'),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  /// رسالة فشل دقيقة بحسب نوع الخطأ؛ وتذكّر دائماً أن البيانات لم تُمسّ إن
  /// كان الفشل قبل الاستبدال أو أثناءه (المعاملة تتراجع).
  static String _restoreError(Object e) {
    if (e is FormatException) {
      return 'الملف غير صالح — ${e.message}';
    }
    if (e is BackupValidationException) {
      return 'لا يمكن استعادة هذه النسخة: ${e.message}';
    }
    if (e is BackupApplyException) {
      return e.message;
    }
    return 'تعذرت الاستعادة — بياناتك الحالية كما هي. ($e)';
  }

  /// «yyyy-MM-dd HH:mm» لوقت النسخة.
  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${SchoolTime.dateKey(t)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// ملخص مختصر لما تحمله النسخة (من التحقق نفسه لا من تخمين).
  static String _restoreContents(BackupInfo info) {
    final Map<String, int> c = info.counts;
    final List<String> parts = <String>[
      'طلاب ${c['students'] ?? 0}',
      'صفوف ${c['classes'] ?? 0}',
      'سنوات ${c['years'] ?? 0}',
      'سجلات حضور ${c['attendance'] ?? 0}',
      'جلسات ${c['sessions'] ?? 0}',
      'إجازات ${c['leaves'] ?? 0}',
      'حصص ${c['lessons'] ?? 0}',
    ];
    if (info.photoCount > 0) {
      parts.add('صور ${info.photoCount}');
    }
    return parts.join('، ');
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('الإعدادات')),
        body: Center(
          child: _loadError == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('تعذر تحميل الإعدادات: $_loadError'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _load,
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
        ),
      );
    }
    // أثناء الاستعادة لا يُسمح بالرجوع: العملية الحساسة تكتب القاعدة كاملة.
    final Widget page = Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _restoring ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (_restoring) ...<Widget>[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text('جارٍ تنفيذ الاستعادة… لا تغلق التطبيق.'),
            const SizedBox(height: 8),
          ],
          TextField(controller: _school, decoration: const InputDecoration(labelText: 'اسم المدرسة')),
          const SizedBox(height: 8),
          TextField(controller: _director, decoration: const InputDecoration(labelText: 'اسم المدير')),
          const SizedBox(height: 8),
          // تسميات قصيرة + `helperText` يلتفّ: التسمية الطويلة داخل حقل نصفي
          // العرض تُقتطع (لا تلتفّ) فتختفي آخر الكلمات.
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _t1,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'الإنذار الأول (أيام)',
                    helperText: 'عتبة التحذير — أيام الغياب',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _t2,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'الإنذار الثاني (أيام)',
                    helperText: 'عتبة الخطر — أيام الغياب',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _dayStart,
                  decoration: const InputDecoration(
                    labelText: 'بداية الدوام',
                    helperText: 'مرجع احتياطي — التأخير يُحسب من بداية الحصة',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _lateAfter,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'دقائق السماح',
                    helperText: 'بعد بداية الحصة يُسجَّل «متأخر»',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pin,
            decoration: const InputDecoration(
              labelText: 'رمز PIN',
              helperText: 'يحمي الإعدادات والتصفير — اتركه فارغاً للتعطيل',
            ),
            obscureText: true,
          ),
          const SizedBox(height: 16),
          const Text(
            'التنبيهات والإشعارات',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _systemNotif,
            title: const Text('إشعارات النظام (خارج التطبيق)'),
            subtitle: const Text(
              'إشعار منبثق على الهاتف عند بلوغ الطالب حد الفصل — '
              'التنبيه داخل التطبيق (زر الجرس) يعمل دائمًا',
            ),
            secondary: const Icon(Icons.notifications),
            onChanged: (bool v) => setState(() => _systemNotif = v),
          ),
          ListTile(
            leading: const Icon(Icons.phone_android),
            title: const Text('صلاحية الإشعارات'),
            subtitle: Text(_permLabel),
            trailing: _permGranted
                ? const Icon(Icons.check_circle, color: Colors.green)
                : const Icon(Icons.gpp_maybe, color: Colors.orange),
          ),
          if (!_permGranted)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton(
                      onPressed: _requestPermission,
                      child: const Text('طلب الصلاحية'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _openNotificationSettings,
                      child: const Text('إعدادات النظام'),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          const Text('أيام الدوام الأسبوعية:'),
          Wrap(
            spacing: 6,
            children: <Widget>[
              for (int wd = 1; wd <= 7; wd++)
                FilterChip(
                  label: Text(SchoolTime.weekdayNames[wd - 1]),
                  selected: _weekdays.contains(wd),
                  onSelected: (bool v) => setState(() {
                    if (v) {
                      _weekdays.add(wd);
                    } else {
                      _weekdays.remove(wd);
                    }
                  }),
                ),
            ],
          ),
          SwitchListTile(
            value: _hijri,
            title: const Text('إظهار التاريخ الهجري'),
            onChanged: (bool v) => setState(() => _hijri = v),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('جدول الحصص'),
            subtitle: const Text(
              'عدد الحصص وأسماؤها وأوقاتها — الحضور يُسجَّل حصةً حصة',
            ),
            onTap: _lessons,
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month),
            title: const Text('العطل الرسمية'),
            onTap: _holidays,
          ),
          ListTile(
            leading: const Icon(Icons.backup),
            title: const Text('نسخ احتياطي ومشاركة'),
            subtitle: const Text('حاوية كاملة: البيانات والإعدادات والصور'),
            onTap: _restoring ? null : _backup,
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('استعادة كاملة من ملف'),
            subtitle: const Text(
              'تستبدل بيانات التطبيق كاملةً ببيانات النسخة — لا دمج',
            ),
            onTap: _restoring ? null : _restore,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info),
            title: const Text('حول التطبيق'),
            subtitle: const Text(
              'المطور: كنان الصائغ — التطبيق حاليًا مجاني (نسخة تجريبية)',
            ),
            onTap: _about,
          ),
        ],
      ),
    );
    return PopScope(canPop: !_restoring, child: page);
  }
}

class _HolidaysEditor extends StatelessWidget {
  const _HolidaysEditor({required this.db});

  final AppDb db;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('العطل الرسمية')),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            final DateTime? d = await showDatePicker(
              context: context,
              initialDate: DateTime.now(),
              firstDate: DateTime(2015),
              lastDate: DateTime(2045),
            );
            if (d == null) {
              return;
            }
            if (!context.mounted) {
              return;
            }
            final TextEditingController title = TextEditingController();
            final bool? ok = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                title: const Text('اسم العطلة'),
                content: TextField(controller: title),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('إلغاء'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('حفظ'),
                  ),
                ],
              ),
            );
            if (ok != true || title.text.trim().isEmpty) {
              return;
            }
            await db.into(db.holidays).insert(
                  HolidaysCompanion(
                    date: Value(SchoolTime.dateKey(d)),
                    title: Value(title.text.trim()),
                  ),
                );
          },
          child: const Icon(Icons.add),
        ),
        body: StreamBuilder<List<Holiday>>(
          stream: db.select(db.holidays).watch(),
          builder: (BuildContext context, AsyncSnapshot<List<Holiday>> snap) {
            final List<Holiday> list = snap.data ?? <Holiday>[];
            if (list.isEmpty) {
              return const Center(child: Text('لا عطل مسجلة'));
            }
            return ListView.builder(
              itemCount: list.length,
              itemBuilder: (BuildContext context, int i) => ListTile(
                title: Text(list[i].title),
                subtitle: Text(list[i].date),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => (db.delete(db.holidays)
                        ..where((h) => h.id.equals(list[i].id)))
                      .go(),
                ),
              ),
            );
          },
        ),
      );
}
