import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../documents/format.dart';

/// Simple read-only encounter view used from the timeline when the full encounter screen is not
/// available, and for encounters shared by the patient (`/shared-with-me/...`). Private notes are
/// only shown when the API includes them (it never does for shared encounters).
class EncounterReadPage extends StatefulWidget {
  const EncounterReadPage({super.key, required this.title, required this.load, this.banner});
  final String title;
  final Future<Map<String, dynamic>> Function() load;

  /// Provenance line shown on top (e.g. "Shared by the patient from X until Y").
  final String? banner;

  @override
  State<EncounterReadPage> createState() => _EncounterReadPageState();
}

class _EncounterReadPageState extends State<EncounterReadPage> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.load();
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static const _fields = <(String, String)>[
    ('chiefComplaint', 'Chief complaint'),
    ('history', 'History'),
    ('diagnosis', 'Diagnosis'),
    ('plan', 'Plan'),
    ('privateNotes', 'Private notes'),
  ];

  String _line(Object? o) {
    if (o is Map) return o.values.where((v) => v != null && '$v'.isNotEmpty).join(' · ');
    return '$o';
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final content = d == null ? const <String, dynamic>{} : ((d['content'] as Map?)?.cast<String, dynamic>() ?? d);
    final rx = (content['prescriptions'] as List?) ?? const [];
    final obs = (d?['observations'] ?? d?['vitals']) as List?;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
                    if (widget.banner != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Chip(label: Text(widget.banner!))),
                    Text(formatTs(d?['encounterDate']), style: Theme.of(context).textTheme.bodySmall),
                    for (final (k, label) in _fields)
                      if (content[k] is String && (content[k] as String).trim().isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(label, style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 4),
                        Text(content[k] as String),
                      ],
                    if (rx.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text('Prescriptions', style: Theme.of(context).textTheme.labelLarge),
                      for (final r in rx) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• ${_line(r)}')),
                    ],
                    if (obs != null && obs.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text('Vitals', style: Theme.of(context).textTheme.labelLarge),
                      for (final o in obs) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• ${o is Map ? '${o['kind'] ?? o['name'] ?? ''}: ${o['value']}' : o}')),
                    ],
                  ]),
                ),
    );
  }
}
