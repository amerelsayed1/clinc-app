import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'patient_repository.dart';
import 'share_form_page.dart';
import 'sharing_models.dart';

const retentionNotice =
    'If a clinic has already added a shared record to its own chart, it keeps that copy after you revoke access. Revoking stops all further viewing right away.';

/// "Sharing" tab: who can see my records, access requests, and the access log.
class SharingPage extends StatefulWidget {
  const SharingPage({super.key, required this.repository, this.onPendingChanged});
  final PatientRepository repository;
  final ValueChanged<int>? onPendingChanged;

  @override
  State<SharingPage> createState() => _SharingPageState();
}

class _SharingPageState extends State<SharingPage> {
  List<Grant>? _grants;
  List<AccessRequest>? _requests;
  String? _error;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final g = await widget.repository.grants();
      final r = await widget.repository.accessRequests();
      if (!mounted) return;
      setState(() {
        _grants = g;
        _requests = r;
        _error = null;
      });
      widget.onPendingChanged?.call(pendingCount(r));
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _revoke(Grant g) async {
    final ok = await confirmDialog(context,
        title: 'Revoke access?',
        message: '${g.recipient.label} will immediately lose access to what you shared. $retentionNotice',
        confirmLabel: 'Revoke access',
        destructive: true);
    if (!ok) return;
    setState(() => _busyId = g.id);
    try {
      await widget.repository.revokeGrant(g.id);
      if (mounted) showSnack(context, 'Access revoked.');
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _deny(AccessRequest r) async {
    final ok = await confirmDialog(context, title: 'Deny request?', message: '${r.doctorName ?? r.clinicName ?? 'The doctor'} will not get access to your records.', confirmLabel: 'Deny', destructive: true);
    if (!ok) return;
    setState(() => _busyId = r.id);
    try {
      await widget.repository.denyRequest(r.id);
      if (mounted) showSnack(context, 'Request denied.');
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, shareErrorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _approve(AccessRequest r) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ApproveSheet(request: r, repository: widget.repository),
    );
    if (done == true) {
      if (mounted) showSnack(context, 'Access granted.');
      await _load();
    }
  }

  Future<void> _newShare() async {
    final created = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ShareFormPage(repository: widget.repository)));
    if (created == true) {
      if (mounted) showSnack(context, 'Shared. You can revoke access at any time.');
      await _load();
    }
  }

  void _openLog({String? grantId}) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccessLogPage(repository: widget.repository, grantId: grantId)));

  @override
  Widget build(BuildContext context) {
    if (_grants == null || _requests == null) {
      return _error != null ? ErrorView(message: _error!, onRetry: _load) : const LoadingView();
    }
    final pending = _requests!.where((r) => r.isPending).toList();
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        floatingActionButton: FloatingActionButton.extended(onPressed: _newShare, icon: const Icon(Icons.share_outlined), label: const Text('Share records')),
        body: Column(children: [
          TabBar(tabs: [
            const Tab(text: 'Who can see'),
            Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('Requests'),
              if (pending.isNotEmpty) ...[const SizedBox(width: 6), Badge(label: Text('${pending.length}'))],
            ])),
            const Tab(text: 'Activity'),
          ]),
          Expanded(
            child: TabBarView(children: [
              _refreshable(_accessTab(context)),
              _refreshable(_requestsTab(context, pending)),
              AccessLogPage(repository: widget.repository, embedded: true),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _refreshable(Widget list) => RefreshIndicator(onRefresh: _load, child: list);

  Widget _empty(IconData icon, String title, String body) => ListView(children: [
        const SizedBox(height: 60),
        Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12), child: Text(body, textAlign: TextAlign.center)),
      ]);

  Widget _accessTab(BuildContext context) {
    final active = _grants!.where((g) => g.isActive).toList();
    final past = _grants!.where((g) => !g.isActive).toList();
    if (active.isEmpty && past.isEmpty) {
      return _empty(Icons.lock_outline, 'Nobody can see your records', 'Your records are private. Tap "Share records" to give a doctor time-limited access.');
    }
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
      ErrorBanner(_error),
      if (active.isEmpty) const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('Nobody currently has access.')),
      for (final g in active) _grantCard(context, g),
      if (past.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.only(top: 12, bottom: 8), child: Text('History', style: t.titleMedium)),
        for (final g in past) _grantCard(context, g),
      ],
    ]);
  }

  Widget _grantCard(BuildContext context, Grant g) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(g.recipient.doctorName ?? 'Doctor', style: t.titleMedium)),
            if (g.isActive && g.expiresSoon) Chip(label: const Text('Expires soon'), backgroundColor: cs.tertiaryContainer, visualDensity: VisualDensity.compact),
            if (!g.isActive) Chip(label: Text(g.status == 'revoked' ? 'Revoked' : 'Expired'), visualDensity: VisualDensity.compact),
          ]),
          if (g.recipient.clinicName != null) Text(g.recipient.clinicName!),
          const SizedBox(height: 8),
          Text('Shared: ${g.scope.summary}'),
          if (g.purpose.isNotEmpty) Text('Purpose: ${g.purpose}'),
          const SizedBox(height: 4),
          Text(
            g.isActive ? 'Expires ${formatDate(g.expiresAt)}' : (g.status == 'revoked' ? 'Revoked ${formatDate(g.revokedAt)}' : 'Expired ${formatDate(g.expiresAt)}'),
            style: t.bodySmall,
          ),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => _openLog(grantId: g.id), child: const Text('Activity')),
            if (g.isActive)
              TextButton(
                onPressed: _busyId == g.id ? null : () => _revoke(g),
                style: TextButton.styleFrom(foregroundColor: cs.error),
                child: const Text('Revoke'),
              ),
          ]),
        ]),
      ),
    );
  }

  Widget _requestsTab(BuildContext context, List<AccessRequest> pending) {
    final t = Theme.of(context).textTheme;
    final past = _requests!.where((r) => !r.isPending).toList();
    if (pending.isEmpty && past.isEmpty) {
      return _empty(Icons.inbox_outlined, 'No access requests', 'When a doctor asks to see your records, the request appears here for you to approve or deny.');
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (pending.isEmpty) const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('No requests are waiting for you.')),
      for (final r in pending)
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.doctorName ?? 'Doctor', style: t.titleMedium),
              if (r.clinicName != null) Text(r.clinicName!),
              const SizedBox(height: 8),
              Text('Purpose: ${r.purpose}'),
              Text('Wants to see: ${r.scope.summary}'),
              Text('For: ${r.requestedDays} days'),
              if (r.sensitive)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Chip(avatar: const Icon(Icons.warning_amber_rounded, size: 18), label: const Text('Includes consultation records (sensitive)'), backgroundColor: Theme.of(context).colorScheme.tertiaryContainer),
                ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: _busyId == r.id ? null : () => _deny(r), child: const Text('Deny'))),
                const SizedBox(width: 12),
                Expanded(child: FilledButton(onPressed: _busyId == r.id ? null : () => _approve(r), child: const Text('Review'))),
              ]),
            ]),
          ),
        ),
      if (past.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.only(top: 12, bottom: 8), child: Text('Earlier requests', style: t.titleMedium)),
        for (final r in past)
          ListTile(
            title: Text(r.doctorName ?? r.clinicName ?? 'Doctor'),
            subtitle: Text('${r.scope.summary} - ${r.status}'),
          ),
      ],
    ]);
  }
}

/// Bottom sheet to approve a request. Can only narrow the request: fewer categories/items, fewer days.
class ApproveSheet extends StatefulWidget {
  const ApproveSheet({super.key, required this.request, required this.repository});
  final AccessRequest request;
  final PatientRepository repository;

  @override
  State<ApproveSheet> createState() => _ApproveSheetState();
}

class _ApproveSheetState extends State<ApproveSheet> {
  late final ApprovalDraft _draft = ApprovalDraft(widget.request);
  bool _ackRetention = false;
  bool _ackSensitive = false;
  bool _busy = false;
  String? _error;
  Map<String, ShareableItem> _titles = {};

  @override
  void initState() {
    super.initState();
    if (widget.request.scope.isItems) {
      widget.repository.shareable().then((l) {
        if (mounted) setState(() => _titles = {for (final i in l) '${i.type}:${i.id}': i});
      }).catchError((_) {});
    }
  }

  Future<void> _submit() async {
    final problem = _draft.validate(ackRetention: _ackRetention, ackSensitive: _ackSensitive);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.approveRequest(widget.request.id, _draft.body(ackRetention: _ackRetention, ackSensitive: _ackSensitive));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = shareErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final t = Theme.of(context).textTheme;
    final sensitive = _draft.effectiveScope?.sensitive ?? false;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Approve request from ${r.doctorName ?? r.clinicName ?? 'a doctor'}', style: t.titleLarge),
          if (r.clinicName != null) Text(r.clinicName!),
          const SizedBox(height: 8),
          Text('Purpose: ${r.purpose}'),
          const SizedBox(height: 12),
          Text('You can share less than requested, but not more.', style: t.bodySmall),
          if (r.scope.isItems)
            for (final i in _draft.offeredItems)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _draft.items.contains(i),
                title: Text(_titles['${i.type}:${i.id}']?.title ?? (i.type == 'encounter' ? 'Consultation' : 'Document')),
                subtitle: Text(_titles['${i.type}:${i.id}']?.date ?? ''),
                onChanged: (v) => setState(() => v == true ? _draft.items.add(i) : _draft.items.remove(i)),
              )
          else
            for (final c in _draft.offeredCategories)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _draft.categories.contains(c),
                title: Text(categoryLabel(c)),
                onChanged: (v) => setState(() => v == true ? _draft.categories.add(c) : _draft.categories.remove(c)),
              ),
          if (r.scope.from != null || r.scope.to != null) Text('Date range: ${r.scope.from ?? 'any'} to ${r.scope.to ?? 'any'}', style: t.bodySmall),
          const SizedBox(height: 8),
          Text('Access for ${_draft.days} ${_draft.days == 1 ? 'day' : 'days'} (requested ${r.requestedDays})'),
          if (_draft.maxDays > 1)
            Slider(
              key: const Key('approve-days'),
              min: 1,
              max: _draft.maxDays.toDouble(),
              divisions: _draft.maxDays - 1,
              value: _draft.days.clamp(1, _draft.maxDays).toDouble(),
              label: '${_draft.days}',
              onChanged: (v) => setState(() => _draft.setDays(v.round())),
            ),
          if (sensitive)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _ackSensitive,
              onChanged: (v) => setState(() => _ackSensitive = v == true),
              title: const Text('I understand this includes my consultation records and I want to share them.'),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _ackRetention,
            onChanged: (v) => setState(() => _ackRetention = v == true),
            title: const Text(retentionNotice),
          ),
          ErrorBanner(_error),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel'))),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(onPressed: _busy ? null : _submit, child: const Text('Approve'))),
          ]),
        ]),
      ),
    );
  }
}

/// Who viewed what and when. Embedded as a tab, or full screen filtered to one grant.
class AccessLogPage extends StatefulWidget {
  const AccessLogPage({super.key, required this.repository, this.grantId, this.embedded = false});
  final PatientRepository repository;
  final String? grantId;
  final bool embedded;

  @override
  State<AccessLogPage> createState() => _AccessLogPageState();
}

class _AccessLogPageState extends State<AccessLogPage> {
  List<AccessLogEntry>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await widget.repository.accessLog(grantId: widget.grantId);
      if (mounted) setState(() => _items = l);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_items == null) {
      body = _error != null ? ErrorView(message: _error!, onRetry: _load) : const LoadingView();
    } else if (_items!.isEmpty) {
      body = ListView(children: const [
        SizedBox(height: 60),
        Icon(Icons.visibility_off_outlined, size: 56),
        Padding(padding: EdgeInsets.all(24), child: Text('Nobody has viewed your shared records yet.', textAlign: TextAlign.center)),
      ]);
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: _items!.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final e = _items![i];
          return ListTile(
            leading: Icon(e.itemType == 'encounter' ? Icons.medical_information_outlined : Icons.description_outlined),
            title: Text('${e.viewerName ?? 'A doctor'} viewed ${e.itemTitle ?? (e.itemType == 'encounter' ? 'a consultation' : 'a document')}'),
            subtitle: Text('${e.clinicName ?? ''} - ${formatDateTime(e.at?.toLocal())}'),
          );
        },
      );
    }
    final content = RefreshIndicator(onRefresh: _load, child: body);
    return widget.embedded ? content : Scaffold(appBar: AppBar(title: const Text('Activity')), body: content);
  }
}
