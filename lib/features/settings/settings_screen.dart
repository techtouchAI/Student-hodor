/// الإعدادات: مدرسة/مدير/أيام الدوام/هجري/حدود الإنذار/PIN/عطل/نسخ ودمج.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/school_time.dart';
import '../../data/backup_service.dart';
import '../../data/db.dart';
import '../../state/providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsState();
}

class _SettingsState extends ConsumerState<SettingsScreen> {
  late TextEditingController _school;
  late TextEditingController _director;
  late TextEditingController _t1;
  late TextEditingController _t2;
  late TextEditingController _pin;
  Set<int> _weekdays = SchoolTime.defaultWorkWeekdays;
  bool _hijri = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _school = TextEditingController();
    _director = TextEditingController();
    _t1 = TextEditingController(text: '10');
    _t2 = TextEditingController(text: '15');
    _pin = TextEditingController();
  }

  Future<void> _load() async {
    final Map<String, String> s = await ref.read(dbProvider).allSettings();
    if (!mounted) {
      return;
    }
    setState(() {
      _school.text = s['school_name'] ?? '';
      _director.text = s['director_name'] ?? '';
      _t1.text = s['alert_threshold_1'] ?? '10';
      _t2.text = s['alert_threshold_2'] ?? '15';
      _pin.text = s['pin'] ?? '';
      _hijri = s['show_hijri'] == '1';
      _weekdays = <int>{
        for (final String w in (s['work_weekdays'] ?? '7,1,2,3,4').split(','))
          int.tryParse(w) ?? 0,
      };
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final AppDb db = ref.read(dbProvider);
    await db.setSetting('school_name', _school.text.trim());
    await db.setSetting('director_name', _director.text.trim());
    await db.setSetting('alert_threshold_1', _t1.text.trim());
    await db.setSetting('alert_threshold_2', _t2.text.trim());
    await db.setSetting('pin', _pin.text.trim());
    await db.setSetting('show_hijri', _hijri ? '1' : '0');
    await db.setSetting('work_weekdays', _weekdays.join(','));
    await db.logAudit('settings_save', '');
    ref.invalidate(settingsProvider);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('حُفظت الإعدادات')));
    }
  }

  Future<void> _holidays() async {
    final AppDb db = ref.read(dbProvider);
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (BuildContext context) => _HolidaysEditor(db: db)),
    );
  }

  Future<void> _backup() async {
    final String path = await BackupService(ref.read(dbProvider)).exportFile();
    await SharePlus.instance.share(
          ShareParams(files: <XFile>[XFile(path)]),
        );
  }

  Future<void> _restoreOrMerge(bool merge) async {
    final FilePickerResult? res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['json'],
    );
    final String? path = res?.files.single.path;
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
          SnackBar(content: Text('دمج: جلسات ${counts['sessions']}، حضور ${counts['attendance']}')),
        );
      }
    } else {
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
      ref.invalidate(currentYearProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('الإعدادات')),
        body: FutureBuilder<void>(future: _load(), builder: (BuildContext context, AsyncSnapshot<void> s) => const Center(child: CircularProgressIndicator())),
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
