import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'patient_repository.dart';
import 'timeline_models.dart';

/// Opens the most specific view available for an entry; entries without their own record get a summary sheet.
void openTimelineEntry(BuildContext context, PatientRepository repo, TimelineEntry e) {
  if (e.opensEncounter) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EncounterDetailPage(repository: repo, entry: e)));
  } else if (e.opensDocument) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DocumentDetailPage(repository: repo, entry: e)));
  } else {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('${e.typeLabel} · ${formatDateTime(e.date.toLocal())}'),
          const SizedBox(height: 4),
          Text(e.provenanceLabel),
          if (e.summary.isNotEmpty) ...[const SizedBox(height: 12), Text(e.summary)],
        ]),
      ),
    );
  }
}

Widget _section(BuildContext context, String label, String text) => text.trim().isEmpty
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(text),
        ]),
      );

/// Published consultation: complaint, diagnosis, plan, prescriptions, vitals. Never history or private notes.
class EncounterDetailPage extends StatefulWidget {
  const EncounterDetailPage({super.key, required this.repository, required this.entry});
  final PatientRepository repository;
  final TimelineEntry entry;

  @override
  State<EncounterDetailPage> createState() => _EncounterDetailPageState();
}

class _EncounterDetailPageState extends State<EncounterDetailPage> {
  EncounterView? _view;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final v = await widget.repository.encounterDetail(widget.entry.id);
      if (mounted) setState(() => _view = v);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _view;
    return Scaffold(
      appBar: AppBar(title: const Text('Visit')),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : v == null
              ? const LoadingView()
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Text(v.chiefComplaint.isEmpty ? 'Consultation' : v.chiefComplaint, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(widget.entry.provenanceLabel),
                  Text(formatDate(v.date?.toLocal())),
                  if (widget.entry.amended) Text('Updated by your doctor (version ${widget.entry.version})'),
                  const SizedBox(height: 16),
                  _section(context, 'Diagnosis', v.diagnosis),
                  _section(context, 'Plan', v.plan),
                  if (v.prescriptions.isNotEmpty) ...[
                    Text('Prescription', style: Theme.of(context).textTheme.labelLarge),
                    for (final p in v.prescriptions)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${p['medication'] ?? ''}'),
                        subtitle: Text([p['dose'], p['frequency'], p['duration'], p['notes']].where((x) => x != null && '$x'.isNotEmpty).join(' · ')),
                      ),
                    const SizedBox(height: 8),
                  ],
                  if (v.vitals.isNotEmpty) ...[
                    Text('Vitals', style: Theme.of(context).textTheme.labelLarge),
                    for (final x in v.vitals) Text('${x['kind']}: ${x['value']} ${x['unit'] ?? ''}'),
                  ],
                ]),
    );
  }
}

/// A document in my history (my upload, or one a doctor published to me). Pages open through short-lived links.
class DocumentDetailPage extends StatefulWidget {
  const DocumentDetailPage({super.key, required this.repository, required this.entry});
  final PatientRepository repository;
  final TimelineEntry entry;

  @override
  State<DocumentDetailPage> createState() => _DocumentDetailPageState();
}

class _DocumentDetailPageState extends State<DocumentDetailPage> {
  DocumentView? _doc;
  final Map<int, String> _links = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await widget.repository.documentDetail(widget.entry.id);
      if (!mounted) return;
      setState(() => _doc = d);
      for (var p = 1; p <= d.pageCount && p <= 20; p++) {
        final path = await widget.repository.documentPageLink(d.id, p);
        if (mounted) setState(() => _links[p] = '${widget.repository.api.baseUrl}$path');
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    return Scaffold(
      appBar: AppBar(title: const Text('Document')),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : d == null
              ? const LoadingView()
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Text(d.title, style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text('${widget.entry.badgeLabel} · ${widget.entry.provenanceLabel}'),
                  Text(formatDate(widget.entry.date.toLocal())),
                  const SizedBox(height: 16),
                  _section(context, 'Notes', d.notes),
                  for (final l in _links.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Image.network(l.value, errorBuilder: (_, _, _) => Text('Page ${l.key} cannot be shown here.')),
                    ),
                ]),
    );
  }
}
