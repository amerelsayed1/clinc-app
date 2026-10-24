import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'settings_models.dart';

/// Time zone, default appointment length and working hours (port of dashboard SettingsPage).
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.api});
  final ApiClient api;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ClinicSettings? _s;
  final _tz = TextEditingController();
  final _slot = TextEditingController();
  String? _loadError;
  String? _error;
  bool _saving = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tz.dispose();
    _slot.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final s = ClinicSettings.fromJson(await widget.api.get('/workspace/settings') as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _s = s;
        _tz.text = s.timezone;
        _slot.text = '${s.slotMinutes}';
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = errorMessage(e));
    }
  }

  ClinicSettings get _current => _s!.copyWith(timezone: _tz.text.trim(), slotMinutes: int.tryParse(_slot.text.trim()) ?? 0);

  Future<void> _save() async {
    final s = _current;
    final problem = s.validate();
    if (problem != null) return setState(() => _error = problem);
    setState(() {
      _saving = true;
      _error = null;
      _saved = false;
    });
    try {
      final saved = ClinicSettings.fromJson(await widget.api.patch('/workspace/settings', body: s.toJson()) as Map<String, dynamic>);
      if (mounted) {
        setState(() {
          _s = saved;
          _saved = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pick(String day, TimeRange r, {required bool start}) async {
    final cur = start ? r.start : r.end;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.parse(cur.substring(0, 2)), minute: int.parse(cur.substring(3))));
    if (t == null) return;
    final v = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() {
      _s = _current.withDay(day, start: start ? v : null, end: start ? null : v);
      _saved = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null && _s == null) return ErrorView(message: _loadError!, onRetry: _load);
    if (_s == null) return const LoadingView();
    return ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: _tz, decoration: const InputDecoration(labelText: 'Time zone', helperText: 'e.g. Africa/Cairo'), onChanged: (_) => _saved = false),
      const SizedBox(height: 16),
      TextField(
        controller: _slot,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Default appointment length (minutes)', helperText: '5 to 120'),
        onChanged: (_) => _saved = false,
      ),
      const SizedBox(height: 24),
      Text('Working hours', style: Theme.of(context).textTheme.titleMedium),
      for (final (key, label) in workingDays) _dayRow(key, label),
      const SizedBox(height: 16),
      if (_error != null) ...[ErrorBanner(_error!), const SizedBox(height: 12)],
      BusyButton(label: 'Save settings', busy: _saving, onPressed: _save),
      if (_saved) const Padding(padding: EdgeInsets.only(top: 8), child: Center(child: Text('Saved'))),
    ]);
  }

  Widget _dayRow(String key, String label) {
    final ranges = _s!.workingHours[key] ?? const <TimeRange>[];
    final r = ranges.isEmpty ? null : ranges.first;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(
        key: ValueKey('day-$key'),
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: r == null ? const Text('Closed') : null,
        value: r != null,
        onChanged: (on) => setState(() {
          _s = _current.withDay(key, open: on);
          _saved = false;
        }),
      ),
      if (r != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            OutlinedButton(key: ValueKey('start-$key'), onPressed: () => _pick(key, r, start: true), child: Text(r.start)),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('to')),
            OutlinedButton(key: ValueKey('end-$key'), onPressed: () => _pick(key, r, start: false), child: Text(r.end)),
          ]),
        ),
    ]);
  }
}
