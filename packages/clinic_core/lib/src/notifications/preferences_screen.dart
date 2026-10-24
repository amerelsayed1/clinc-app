import 'package:flutter/material.dart';

import '../ui/common.dart';
import 'controllers.dart';
import 'models.dart';
import 'strings.dart';

/// F10-4 preferences: language, channels, quiet hours, per-type opt-outs (security rows are locked).
class NotificationPreferencesScreen extends StatefulWidget {
  const NotificationPreferencesScreen({super.key, required this.kit});
  final NotificationsKit kit;

  @override
  State<NotificationPreferencesScreen> createState() => _NotificationPreferencesScreenState();
}

class _NotificationPreferencesScreenState extends State<NotificationPreferencesScreen> {
  NotificationPreferences? _prefs;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final p = await widget.kit.repository.preferences();
      if (mounted) setState(() => _prefs = p);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _save(Map<String, dynamic> patch) async {
    setState(() => _saving = true);
    try {
      final p = await widget.kit.repository.savePreferences(patch);
      if (!mounted) return;
      setState(() => _prefs = p);
      if (patch.containsKey('locale')) widget.kit.locale.set(Locale(p.locale));
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickTime(bool start) async {
    final p = _prefs!;
    final cur = start ? p.quietHours?.start ?? '22:00' : p.quietHours?.end ?? '07:00';
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.parse(cur.substring(0, 2)), minute: int.parse(cur.substring(3, 5))));
    if (t == null) return;
    final v = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final other = start ? p.quietHours?.end ?? '07:00' : p.quietHours?.start ?? '22:00';
    await _save({'quietHours': {'start': start ? v : other, 'end': start ? other : v, 'timezone': p.quietHours?.timezone ?? 'Africa/Cairo'}});
  }

  @override
  Widget build(BuildContext context) {
    final s = CareStrings.of(context);
    final p = _prefs;
    return Scaffold(
      appBar: AppBar(title: Text(s.preferences)),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : p == null
              ? const LoadingView()
              : ListView(padding: const EdgeInsets.only(bottom: 32), children: [
                  if (_saving) const LinearProgressIndicator(),
                  _Section(s.language),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<String>(
                      key: const ValueKey('locale-picker'),
                      segments: const [ButtonSegment(value: 'en', label: Text('English')), ButtonSegment(value: 'ar', label: Text('العربية'))],
                      selected: {Localizations.localeOf(context).languageCode == 'ar' ? 'ar' : 'en'},
                      onSelectionChanged: (v) => _save({'locale': v.first}),
                    ),
                  ),
                  _Section(s.channels),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(s.channelsHelp, style: Theme.of(context).textTheme.bodySmall)),
                  SwitchListTile(
                    key: const ValueKey('channel-push'),
                    title: Text(s.channelPush),
                    value: p.channels.contains('push'),
                    onChanged: (on) => _save({'channels': _toggle(p.channels, 'push', on)}),
                  ),
                  SwitchListTile(
                    key: const ValueKey('channel-sms'),
                    title: Text(s.channelSms),
                    value: p.channels.contains('sms'),
                    onChanged: (on) => _save({'channels': _toggle(p.channels, 'sms', on)}),
                  ),
                  _Section(s.quietHours),
                  SwitchListTile(
                    key: const ValueKey('quiet-switch'),
                    title: Text(s.quietHours),
                    subtitle: Text(s.quietHoursHelp),
                    value: p.quietHours != null,
                    onChanged: (on) => _save({'quietHours': on ? {'start': '22:00', 'end': '07:00', 'timezone': 'Africa/Cairo'} : null}),
                  ),
                  if (p.quietHours != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(children: [
                        Expanded(child: OutlinedButton(key: const ValueKey('quiet-start'), onPressed: () => _pickTime(true), child: Text('${s.quietFrom} ${p.quietHours!.start}'))),
                        const SizedBox(width: 12),
                        Expanded(child: OutlinedButton(key: const ValueKey('quiet-end'), onPressed: () => _pickTime(false), child: Text('${s.quietTo} ${p.quietHours!.end}'))),
                      ]),
                    ),
                  _Section(s.types),
                  for (final t in p.types)
                    t.mandatory
                        ? ListTile(
                            key: ValueKey('type-${t.type}'),
                            leading: const Icon(Icons.lock_outline),
                            title: Text(s.typeLabel(t.type)),
                            trailing: Text(s.alwaysOn, style: Theme.of(context).textTheme.bodySmall),
                          )
                        : SwitchListTile(
                            key: ValueKey('type-${t.type}'),
                            title: Text(s.typeLabel(t.type)),
                            value: !p.disabledTypes.contains(t.type),
                            onChanged: (on) => _save({'disabledTypes': _toggle(p.disabledTypes, t.type, !on)}),
                          ),
                ]),
    );
  }

  List<String> _toggle(List<String> list, String v, bool include) => include ? ({...list, v}.toList()) : list.where((x) => x != v).toList();
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}
