import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'admin_repository.dart';

/// F11-1: run the hash-chain verification across every clinic's audit log and see earlier runs (including the hourly job).
class AuditVerificationPage extends StatefulWidget {
  const AuditVerificationPage({super.key, required this.repository});
  final AdminRepository repository;

  @override
  State<AuditVerificationPage> createState() => _AuditVerificationPageState();
}

class _AuditVerificationPageState extends State<AuditVerificationPage> {
  List<ChainVerification>? _history;
  ChainVerification? _latest;
  String? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final h = await widget.repository.verifications();
      if (mounted) setState(() => _history = h);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final r = await widget.repository.verifyAudit();
      if (mounted) setState(() => _latest = r);
      await _loadHistory();
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Every clinic keeps a tamper-evident chain of audit entries. Verification re-computes each chain and reports the first entry that does not match.'),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _running ? null : _run,
        icon: _running ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.fact_check_outlined),
        label: const Text('Verify all audit chains'),
      ),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: scheme.error))),
      if (_latest != null) ...[
        const SizedBox(height: 12),
        Card(
          key: const Key('latest-result'),
          color: _latest!.valid ? scheme.primaryContainer : scheme.errorContainer,
          child: ListTile(
            leading: Icon(_latest!.valid ? Icons.verified_outlined : Icons.gpp_bad_outlined),
            title: Text(_latest!.valid ? 'All chains intact' : 'Tampering detected'),
            subtitle: Text(_latest!.valid
                ? '${_latest!.chainsChecked} chains, ${_latest!.entriesChecked} entries checked'
                : 'Broken: ${_latest!.broken.join(', ')}. Treat as a security incident (see the runbook).'),
          ),
        ),
      ],
      const SizedBox(height: 16),
      Text('Earlier runs', style: Theme.of(context).textTheme.titleMedium),
      if (_history == null && _error == null) const Padding(padding: EdgeInsets.all(16), child: LoadingView()),
      for (final h in _history ?? const <ChainVerification>[])
        ListTile(
          dense: true,
          leading: Icon(h.valid ? Icons.check_circle_outline : Icons.error_outline, color: h.valid ? null : scheme.error),
          title: Text(h.valid ? 'Intact' : 'Broken: ${h.broken.join(', ')}'),
          subtitle: Text('${formatDateTime(h.ranAt?.toLocal())} · ${h.chainsChecked} chains · ${h.entriesChecked} entries'),
        ),
    ]);
  }
}
