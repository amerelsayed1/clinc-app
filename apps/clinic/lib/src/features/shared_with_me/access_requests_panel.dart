import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import 'shared_api.dart';
import 'shared_models.dart';

/// Patient-detail "sharing" tab: ask a connected patient for records held elsewhere, and track this
/// clinic's requests (cancel while pending). Sending/cancelling needs `clinical.write`; the list `clinical.read`.
///
/// [relationshipId] is the care-relationship id (the id used by `/patients/:id`).
class AccessRequestsPanel extends StatefulWidget {
  const AccessRequestsPanel(this.session, {super.key, required this.relationshipId, required this.name, this.hasAccount = true, this.api});
  final ClinicSession session;
  final String relationshipId;
  final String name;

  /// False when the patient has not signed up to the app (a request cannot be delivered).
  final bool hasAccount;

  /// Injectable for tests; defaults to one built from the session.
  final SharedApi? api;

  @override
  State<AccessRequestsPanel> createState() => _AccessRequestsPanelState();
}

class _AccessRequestsPanelState extends State<AccessRequestsPanel> {
  late final SharedApi _api = widget.api ?? SharedApi(widget.session.api);
  List<AccessRequest>? _requests;
  String? _error;
  String? _actionError;
  bool _loading = true;
  final Set<String> _busy = {};

  bool get _canRequest => widget.session.can(Perm.clinicalWrite);
  bool get _canRead => widget.session.can(Perm.clinicalRead);

  @override
  void initState() {
    super.initState();
    if (_canRead) {
      _load();
    } else {
      _loading = false;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = _requests == null;
      _error = null;
    });
    try {
      final r = await _api.accessRequests();
      if (mounted) setState(() => _requests = r);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cancel(AccessRequest r) async {
    final ok = await confirmDialog(
      context,
      title: 'Cancel this request?',
      message: 'The patient will no longer be able to approve it.',
      confirmLabel: 'Cancel request',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy.add(r.id);
      _actionError = null;
    });
    try {
      await _api.cancelAccessRequest(r.id);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  Future<void> _compose() async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AccessRequestForm(api: _api, relationshipId: widget.relationshipId, enabled: widget.hasAccount),
    );
    if (sent == true && mounted) {
      showSnack(context, 'Request sent to ${widget.name}');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canRead && !_canRequest) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text('You do not have access to sharing requests.')),
      );
    }
    if (_loading) return const LoadingView();
    if (_error != null && _requests == null) return ErrorView(message: _error!, onRetry: _load);
    final reqs = _requests ?? const <AccessRequest>[];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Records held elsewhere', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Ask ${widget.name} to share records from other clinics. The patient must be registered in the CareLink app and connected to your clinic, and decides what to share and for how long.'
            '${widget.hasAccount ? '' : ' This patient has not signed up to the app yet, so a request cannot be delivered.'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (_canRequest)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const ValueKey('request-access'),
                onPressed: _compose,
                icon: const Icon(Icons.send_outlined),
                label: const Text('Request access to records held elsewhere'),
              ),
            ),
          const SizedBox(height: 12),
          if (_actionError != null) ErrorBanner(_actionError),
          if (_error != null) ErrorBanner(_error),
          Text('This clinic\'s requests', style: Theme.of(context).textTheme.titleSmall),
          if (reqs.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No access requests yet.')),
          for (final r in reqs)
            Card(
              child: ListTile(
                key: ValueKey('req-${r.id}'),
                title: Text('${r.scope.text}${r.sensitive ? ' · sensitive' : ''}'),
                subtitle: Text('${r.purpose}\n${r.requestedDays} days · sent ${formatDateTime(r.createdAt)} by ${r.doctorName}'),
                isThreeLine: true,
                trailing: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(r.statusLabel, style: Theme.of(context).textTheme.labelMedium),
                    if (r.isPending && _canRequest)
                      SizedBox(
                        height: 32,
                        child: TextButton(
                          key: ValueKey('cancel-${r.id}'),
                          onPressed: _busy.contains(r.id) ? null : () => _cancel(r),
                          child: const Text('Cancel'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bottom-sheet form: category checkboxes, optional date range, purpose, days.
class AccessRequestForm extends StatefulWidget {
  const AccessRequestForm({super.key, required this.api, required this.relationshipId, this.enabled = true});
  final SharedApi api;
  final String relationshipId;
  final bool enabled;

  @override
  State<AccessRequestForm> createState() => _AccessRequestFormState();
}

class _AccessRequestFormState extends State<AccessRequestForm> {
  final Set<String> _cats = {'lab_result', 'imaging', 'report'};
  final _purpose = TextEditingController();
  final _days = TextEditingController(text: '30');
  final _from = TextEditingController();
  final _to = TextEditingController();
  bool _busy = false;
  String? _error;

  int get _max => maxDaysFor(_cats);
  int get _daysValue => (int.tryParse(_days.text) ?? 30).clamp(1, _max);

  @override
  void dispose() {
    _purpose.dispose();
    _days.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController c) async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: now, firstDate: DateTime(1990), lastDate: now);
    if (d != null) setState(() => c.text = formatDate(d));
  }

  bool get _valid => widget.enabled && _cats.isNotEmpty && _purpose.text.trim().length >= 3;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.requestAccess(
        widget.relationshipId,
        buildAccessRequestBody(categories: _cats.toList(), purpose: _purpose.text, days: _daysValue, from: _from.text, to: _to.text),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorMessage(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sensitive = _cats.contains('encounters');
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Request access', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            for (final c in shareCategoryLabels.keys)
              CheckboxListTile(
                key: ValueKey('cat-$c'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(shareCategoryLabels[c]!),
                value: _cats.contains(c),
                onChanged: (v) => setState(() {
                  v == true ? _cats.add(c) : _cats.remove(c);
                  _days.text = _daysValue.toString();
                }),
              ),
            if (sensitive)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Consultation records are sensitive: they can be requested for at most $sensitiveMaxDays days and the patient confirms separately.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            TextField(
              key: const ValueKey('purpose'),
              controller: _purpose,
              maxLength: 300,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Purpose', hintText: 'e.g. Review prior cardiology work-up'),
            ),
            TextField(
              key: const ValueKey('days'),
              controller: _days,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: 'Days of access (max $_max)'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _from,
                    readOnly: true,
                    onTap: () => _pickDate(_from),
                    decoration: const InputDecoration(labelText: 'From (optional)', suffixIcon: Icon(Icons.event)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _to,
                    readOnly: true,
                    onTap: () => _pickDate(_to),
                    decoration: const InputDecoration(labelText: 'To (optional)', suffixIcon: Icon(Icons.event)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (!widget.enabled) const ErrorBanner('This patient has not signed up to the app yet, so a request cannot be delivered.'),
            ErrorBanner(_error),
            SizedBox(
              width: double.infinity,
              child: BusyButton(label: 'Send request', busy: _busy, onPressed: _valid ? _send : null),
            ),
          ],
        ),
      ),
    );
  }
}
