import 'dart:convert';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'patient_repository.dart';
import 'privacy_models.dart';

/// Hands the exported JSON to the system share sheet (save to Files / Drive, email, ...). Injectable for tests.
typedef JsonFileSharer = Future<void> Function(String filename, String json);

Future<void> shareJsonFile(String filename, String json) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile.fromData(utf8.encode(json), mimeType: 'application/json', name: filename)],
    fileNameOverrides: [filename],
    title: 'My CareLink data',
  ));
}

/// F11-7 / F11-8: data export, correction requests and the optional app lock.
class PrivacyPage extends StatefulWidget {
  const PrivacyPage({super.key, required this.repository, this.sharer = shareJsonFile});
  final PatientRepository repository;
  final JsonFileSharer sharer;

  @override
  State<PrivacyPage> createState() => _PrivacyPageState();
}

class _PrivacyPageState extends State<PrivacyPage> {
  List<CorrectionRequest>? _requests;
  String? _loadError;
  bool _exporting = false;
  String? _exportJson;
  String? _exportSummary;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    try {
      final r = await widget.repository.correctionRequests();
      if (mounted) setState(() => _requests = r);
    } catch (e) {
      if (mounted) setState(() => _loadError = errorMessage(e));
    }
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final data = await widget.repository.exportData();
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final n = (data['encounters'] as List?)?.length ?? 0;
      final d = (data['documents'] as List?)?.length ?? 0;
      if (mounted) {
        setState(() {
          _exportJson = json;
          _exportSummary = '$n consultation${n == 1 ? '' : 's'}, $d document${d == 1 ? '' : 's'}';
        });
      }
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _save() async {
    try {
      await widget.sharer('carelink-my-data-${formatDate(DateTime.now())}.json', _exportJson!);
    } catch (_) {
      if (mounted) showSnack(context, 'Could not open the share sheet. You can copy the data instead.', error: true);
    }
  }

  Future<void> _newRequest() async {
    final sent = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => CorrectionRequestPage(repository: widget.repository)));
    if (sent == true) _loadRequests();
  }

  @override
  Widget build(BuildContext context) {
    final lock = AppLockScope.maybeOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy and data')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (lock != null) Card(child: AppLockTile(controller: lock)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Download my data', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('A copy of your profile, clinics, published consultations, documents you can see, sharing grants and who viewed your shared records. Notes your doctor keeps private are not included. Each download is recorded.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _exporting ? null : _export,
                icon: _exporting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download_outlined),
                label: const Text('Prepare my data'),
              ),
              if (_exportJson != null) ...[
                const SizedBox(height: 12),
                Text('Ready: $_exportSummary', key: const Key('export-summary')),
                const SizedBox(height: 8),
                Wrap(spacing: 8, children: [
                  OutlinedButton.icon(onPressed: _save, icon: const Icon(Icons.ios_share), label: const Text('Save or share file')),
                  OutlinedButton.icon(onPressed: () => copyToClipboard(context, _exportJson!, label: 'Copied to clipboard'), icon: const Icon(Icons.copy), label: const Text('Copy')),
                ]),
                const SizedBox(height: 4),
                Text('This file contains your health information. Only share it with people you trust.', style: Theme.of(context).textTheme.bodySmall),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Ask for a correction', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('If something in your record is wrong, tell the clinic. They review your request; nothing in your record changes until your doctor decides.'),
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: _newRequest, icon: const Icon(Icons.edit_note), label: const Text('Request a correction')),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        if (_loadError != null) Text(_loadError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_requests != null && _requests!.isNotEmpty) ...[
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('My requests', style: Theme.of(context).textTheme.titleMedium)),
          for (final r in _requests!)
            Card(
              child: ListTile(
                title: Text(r.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  if (r.clinicName != null) r.clinicName!,
                  switch (r.status) { 'open' => 'Waiting for the clinic', 'resolved' => 'Resolved', _ => 'Not changed' },
                  if (r.resolutionNote != null && r.resolutionNote!.isNotEmpty) 'Reply: ${r.resolutionNote}',
                ].join('\n')),
                isThreeLine: r.resolutionNote != null,
                trailing: Icon(r.status == 'open' ? Icons.hourglass_empty : r.status == 'resolved' ? Icons.check_circle_outline : Icons.info_outline),
              ),
            ),
        ],
      ]),
    );
  }
}

class CorrectionRequestPage extends StatefulWidget {
  const CorrectionRequestPage({super.key, required this.repository});
  final PatientRepository repository;

  @override
  State<CorrectionRequestPage> createState() => _CorrectionRequestPageState();
}

class _CorrectionRequestPageState extends State<CorrectionRequestPage> {
  late final Future<List<CorrectableRecord>> _records = widget.repository.correctableRecords();
  final _text = TextEditingController();
  CorrectableRecord? _picked;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await widget.repository.requestCorrection(targetType: _picked!.type, targetId: _picked!.id, description: _text.text);
      if (!mounted) return;
      showSnack(context, 'Request sent to your clinic');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Request a correction')),
        body: FutureBuilder<List<CorrectableRecord>>(
          future: _records,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(message: errorMessage(snap.error!));
            if (!snap.hasData) return const LoadingView();
            final records = snap.data!;
            if (records.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('There are no clinic records to correct yet.')));
            return ListenableBuilder(
              listenable: _text,
              builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
                Text('Which record is wrong?', style: Theme.of(context).textTheme.titleMedium),
                RadioGroup<CorrectableRecord>(
                  groupValue: _picked,
                  onChanged: (v) => setState(() => _picked = v),
                  child: Column(children: [
                    for (final r in records) RadioListTile<CorrectableRecord>(value: r, title: Text(r.title), subtitle: Text(r.subtitle)),
                  ]),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _text,
                  maxLines: 5,
                  maxLength: 2000,
                  decoration: const InputDecoration(labelText: 'What should be corrected?', alignLabelWithHint: true, border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _picked == null || _text.text.trim().length < 5 || _sending ? null : _send,
                  child: const Text('Send to clinic'),
                ),
              ]),
            );
          },
        ),
      );
}
