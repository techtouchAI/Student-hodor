/// الإعدادات: مدرسة/مدير/أيام الدوام/هجري/حدود الإنذار/نافذة التأخر/PIN/عطل/نسخ ودمج.
library;

import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_info.dart';
import '../../core/school_time.dart';
import '../../data/backup_service.dart';
import '../../data/db.dart';
import '../../data/error_log.dart';
import '../../features/diagnostics/diagnostics_screen.dart';
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
  bool _loaded = false;
  String? _loadError;

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
        _hijri = s['show_hijri'] == '1';
        _weekdays = <int>{
          for (final String w in (s['work_weekdays'] ?? '7,1,2,3,4').split(','))
            int.tryParse(w) ?? 0,
        };
        _loaded = true;
        _loadError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loadError = '$e');
      }
    }
  }

  Future<void> _diagnostics() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const DiagnosticsScreen(),
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
    await db.setSetting('day_start', _dayStart.text.trim());
    await db.setSetting('late_after_minutes', _lateAfter.text.trim());
    await db.setSetting('show_hijri', _hijri ? '1' : '0');
    await db.setSetting('work_weekdays', _weekdays.join(','));
    await db.logAudit('settings_save', '');
    ref.invalidate(settingsProvider);
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
    try {
      final String path = await BackupService(ref.read(dbProvider)).exportFile();
      await SharePlus.instance.share(
        ShareParams(files: <XFile>[XFile(path)]),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذر النسخ الاحتياطي: $e')));
      }
    }
  }

  Future<void> _restoreOrMerge(bool merge) async {
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['json'],
      );
      final String? path = picked.isEmpty ? null : picked.single.path;
      if (path == null) {
        return;
      }
      final String text = await File(path).readAsString();
      final AppDb db = ref.read(dbProvider);
      final BackupService svc = BackupService(db);
      if (merge) {
        final Map<String, int> counts = await svc.mergeImport(text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'دمج: جلسات ${counts['sessions']}، حضور ${counts['attendance']}',
              ),
            ),
          );
        }
      } else {
        if (!mounted) {
          return;
        }
        final bool? ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('استرجاع كامل'),
            content: const Text('سيستبدل كل البيانات الحالية بمحتوى الملف. متابعة؟'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('تراجع'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('استرجاع'),
              ),
            ],
          ),
        );
        if (ok != true) {
          return;
        }
        await svc.restoreFull(text);
        ref.invalidate(settingsProvider);
        ref.invalidate(effectiveSettingsProvider);
        ref.invalidate(currentYearProvider);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('تم الاسترجاع')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('الملف غير صالح أو تعذرت القراءة: $e')),
        );
      }
    }
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات'),
        actions: <Widget>[
          IconButton(icon: const Icon(Icons.save), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(controller: _school, decoration: const InputDecoration(labelText: 'اسم المدرسة')),
          const SizedBox(height: 8),
          TextField(controller: _director, decoration: const InputDecoration(labelText: 'اسم المدير')),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(child: TextField(controller: _t1, decoration: const InputDecoration(labelText: 'حد الإنذار الأول %'), keyboardType: TextInputType.number)),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _t2, decoration: const InputDecoration(labelText: 'حد الإنذار الثاني %'), keyboardType: TextInputType.number)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(child: TextField(controller: _dayStart, decoration: const InputDecoration(labelText: 'بداية اليوم (08:00)'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _lateAfter, decoration: const InputDecoration(labelText: 'دقائق السماح قبل «متأخر»'), keyboardType: TextInputType.number)),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pin,
            decoration: const InputDecoration(
              labelText: 'PIN حماية الإعدادات/التصفير (اتركه فارغاً للتعطيل)',
            ),
            obscureText: true,
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
            leading: const Icon(Icons.calendar_month),
            title: const Text('العطل الرسمية'),
            onTap: _holidays,
          ),
          ListTile(
            leading: const Icon(Icons.backup),
            title: const Text('نسخ احتياطي ومشاركة'),
            onTap: _backup,
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('استرجاع كامل من ملف'),
            onTap: () => _restoreOrMerge(false),
          ),
          ListTile(
            leading: const Icon(Icons.merge),
            title: const Text('دمج جلسات جهاز آخر'),
            onTap: () => _restoreOrMerge(true),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bug_report),
            title: const Text('التشخيص وسجل الأعطال'),
            subtitle: const Text(
              'الإصدار ${AppInfo.version} — عند أي شاشة بيضاء/فارغة أرسل هذا التقرير',
            ),
            onTap: _diagnostics,
          ),
        ],
      ),
    );
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
