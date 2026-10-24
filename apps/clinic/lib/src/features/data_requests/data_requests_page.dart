import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'data_requests_api.dart';
import 'data_requests_models.dart';

/// Patients' correction requests (decide with a note) and the retention policy / legal holds.
///
/// Deciding never edits a clinical record: if a correction is justified, amend the consultation
/// (which keeps the earlier version) and then mark the request resolved.
class DataRequestsPage extends StatefulWidget {
  const DataRequestsPage({super.key, required this.api, required this.canDecide, this.canViewRetention = true, this.canLiftHold = false});
  final DataRequestsApi api;
  final bool canDecide; // clinical.write
  final bool canViewRetention; // audit.read
  final bool canLiftHold; // relationships.manage

  @override
  State<DataRequestsPage> createState() => _DataRequestsPageState();
}

class _DataRequestsPageState extends State<DataRequestsPage> {
  String _status = 'open';
  List<DataRequest>? _requests;
  Retention? _retention;
  String? _retentionError;
  String? _error;
  String? _actionError;
  bool _loading = true;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _requests == null;
      _error = null;
    });
    try {
      final r = await widget.api.list(_status);
      if (mounted) setState(() => _requests = r);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (widget.canViewRetention) {
      try {
        final r = await widget.api.retention();
        if (mounted) {
          setState(() {
            _retention = r;
            _retentionError = null;
          });
        }
      } catch (e) {
        if (mounted) setState(() => _retentionError = errorMessage(e));
      }
    }
  }

  Future<void> _decide(DataRequest r, bool resolve) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _NoteDialog(resolve: resolve, request: r),
    );
    if (note == null || !mounted) return;
    setState(() {
      _busy.add(r.id);
      _actionError = null;
    });
    try {
      resolve ? await widget.api.resolve(r.id, note) : await widget.api.reject(r.id, note);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  Future<void> _lift(LegalHold h) async {
    final ok = await confirmDialog(
      context,
      title: 'Lift legal hold?',
      message: 'Deletion rules apply again to ${h.fullName}\'s documents. The change is recorded in the audit log.',
      confirmLabel: 'Lift hold',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy.add(h.patientId);
      _actionError = null;
    });
    try {
      await widget.api.liftLegalHold(h.patientId);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(h.patientId));
    }
  }

  void _setStatus(String s) {
    if (s == _status) return;
    setState(() {
      _status = s;
      _requests = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null && _requests == null) return ErrorView(message: _error!, onRetry: _load);
    final reqs = _requests ?? const <DataRequest>[];
    final t = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Patients can ask you to correct a record. Nothing changes automatically: if a correction is justified, amend the consultation (which keeps the earlier version), then mark the request resolved.',
            style: t.bodySmall,
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            key: const ValueKey('status'),
            segments: const [
              ButtonSegment(value: 'open', label: Text('Open')),
              ButtonSegment(value: 'resolved', label: Text('Resolved')),
              ButtonSegment(value: 'rejected', label: Text('Rejected')),
            ],
            selected: {_status},
            onSelectionChanged: (s) => _setStatus(s.first),
          ),
          const SizedBox(height: 8),
          if (_actionError != null) ErrorBanner(_actionError),
          if (_error != null) ErrorBanner(_error),
          if (reqs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('No $_status requests.')),
            ),
          for (final r in reqs)
            Card(
              key: ValueKey('dr-${r.id}'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.patientName, style: t.titleSmall),
                    Text(
                      '${r.patientNumber == null ? '' : '#${r.patientNumber} · '}${r.targetText} · ${formatDate(r.createdAt)}',
                      style: t.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(r.description),
                    if (!r.isOpen && (r.resolutionNote ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('${r.status}: ${r.resolutionNote}', style: t.bodySmall),
                      ),
                    if (r.isOpen && widget.canDecide)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            FilledButton(
                              key: ValueKey('resolve-${r.id}'),
                              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                              onPressed: _busy.contains(r.id) ? null : () => _decide(r, true),
                              child: const Text('Mark resolved'),
                            ),
                            OutlinedButton(
                              key: ValueKey('reject-${r.id}'),
                              onPressed: _busy.contains(r.id) ? null : () => _decide(r, false),
                              child: const Text('Reject'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (widget.canViewRetention) ...[
            const SizedBox(height: 16),
            Text('Retention', style: t.titleMedium),
            const SizedBox(height: 4),
            if (_retentionError != null) ErrorBanner(_retentionError),
            if (_retention != null) ...[
              Text(
                'Clinical records are kept for ${_retention!.clinicalRecordYears} years and the audit log for ${_retention!.auditLogYears} years (policy pending legal review). A legal hold overrides every deletion.',
                style: t.bodySmall,
              ),
              const SizedBox(height: 8),
              if (_retention!.holds.isEmpty) const Text('No records under legal hold.'),
              for (final h in _retention!.holds)
                Card(
                  child: ListTile(
                    key: ValueKey('hold-${h.patientId}'),
                    title: Text(h.fullName),
                    subtitle: Text('${h.reason}\nSince ${formatDate(h.setAt)}'),
                    isThreeLine: true,
                    trailing: widget.canLiftHold
                        ? TextButton(
                            key: ValueKey('lift-${h.patientId}'),
                            onPressed: _busy.contains(h.patientId) ? null : () => _lift(h),
                            child: const Text('Lift'),
                          )
                        : null,
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.resolve, required this.request});
  final bool resolve;
  final DataRequest request;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _c.text.trim().length >= 3;
    return AlertDialog(
      title: Text(widget.resolve ? 'Mark as resolved' : 'Reject request'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.resolve
                ? 'This does not edit the record. Amend the consultation first if a correction is justified, then explain what you did.'
                : 'Explain to the patient why the record stays as it is.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('note'),
            controller: _c,
            autofocus: true,
            maxLength: 1000,
            maxLines: 3,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Your reply to the patient (required)'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('note-submit'),
          onPressed: ok ? () => Navigator.pop(context, _c.text.trim()) : null,
          child: Text(widget.resolve ? 'Resolve' : 'Reject'),
        ),
      ],
    );
  }
}
