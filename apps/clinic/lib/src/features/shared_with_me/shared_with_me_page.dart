import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'shared_api.dart';
import 'shared_models.dart';

const _goneMessage = 'This share is no longer available. It may have expired or been revoked by the patient.';

/// Shown on every shared view: a time-limited copy, not part of the clinic's own record.
class SharedBanner extends StatelessWidget {
  const SharedBanner({super.key, required this.expiresAt, this.patientName});
  final DateTime? expiresAt;
  final String? patientName;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final who = (patientName == null || patientName!.isEmpty) ? '' : ' $patientName';
    return Container(
      key: const ValueKey('shared-banner'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Text(
        'Shared by patient$who - provenance: not authored by your clinic. Access expires ${formatDateTime(expiresAt)} and every view is logged for the patient.',
        style: TextStyle(color: cs.onTertiaryContainer),
      ),
    );
  }
}

class ProvenanceBadge extends StatelessWidget {
  const ProvenanceBadge(this.provenance, {super.key});
  final String provenance;

  @override
  Widget build(BuildContext context) {
    final unverified = provenance == patientUnverified;
    final cs = Theme.of(context).colorScheme;
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(provenanceLabel(provenance)),
      backgroundColor: unverified ? cs.secondaryContainer : cs.primaryContainer,
    );
  }
}

/// A shared item is gone (revoked or expired, the API answers 404 for both).
class _GoneView extends StatelessWidget {
  const _GoneView({this.onBackToList});
  final VoidCallback? onBackToList;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_off, size: 40, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          const Text(_goneMessage, textAlign: TextAlign.center, key: ValueKey('share-gone')),
          if (onBackToList != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onBackToList, child: const Text('Back to shared records')),
          ],
        ],
      ),
    ),
  );
}

/// Nav entry "Shared with me": active grants patients gave this clinic.
class SharedWithMePage extends StatefulWidget {
  const SharedWithMePage({super.key, required this.api});
  final SharedApi api;

  @override
  State<SharedWithMePage> createState() => _SharedWithMePageState();
}

class _SharedWithMePageState extends State<SharedWithMePage> {
  List<SharedGrant>? _grants;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _grants == null;
      _error = null;
    });
    try {
      final g = await widget.api.grants();
      if (mounted) setState(() => _grants = g);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(SharedGrant g) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SharedGrantPage(api: widget.api, grant: g),
      ),
    );
    if (mounted) _load(); // the grant may have been revoked or expired meanwhile
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null && _grants == null) return ErrorView(message: _error!, onRetry: _load);
    final grants = _grants ?? const <SharedGrant>[];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Records patients have chosen to share with you for a limited time. These are the patient\'s copies, not part of your clinic\'s chart, and access ends automatically.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (_error != null) ErrorBanner(_error),
          if (grants.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text(
                  'Nothing is currently shared with you.\nYou can request access from a connected patient\'s page.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          for (final g in grants)
            Card(
              child: ListTile(
                key: ValueKey('grant-${g.id}'),
                leading: const CircleAvatar(child: Icon(Icons.folder_shared_outlined)),
                title: Text(g.patientName),
                subtitle: Text('${g.scope.text}${g.purpose.isEmpty ? '' : '\n${g.purpose}'}\nExpires ${formatDateTime(g.expiresAt)}'),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(g),
              ),
            ),
        ],
      ),
    );
  }
}

/// Items of one grant with provenance badges.
class SharedGrantPage extends StatefulWidget {
  const SharedGrantPage({super.key, required this.api, required this.grant});
  final SharedApi api;
  final SharedGrant grant;

  @override
  State<SharedGrantPage> createState() => _SharedGrantPageState();
}

class _SharedGrantPageState extends State<SharedGrantPage> {
  List<SharedItem>? _items;
  String? _error;
  bool _gone = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _items == null;
      _error = null;
    });
    try {
      final i = await widget.api.items(widget.grant.id);
      if (mounted) setState(() => _items = i);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (isGone(e)) {
          _gone = true;
        } else {
          _error = errorMessage(e);
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openItem(SharedItem i) async {
    final g = widget.grant;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => i.isEncounter
            ? SharedEncounterPage(api: widget.api, grant: g, itemId: i.id)
            : SharedDocumentPage(api: widget.api, grant: g, itemId: i.id),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.grant;
    Widget body;
    if (_loading) {
      body = const LoadingView();
    } else if (_gone) {
      body = _GoneView(onBackToList: () => Navigator.maybePop(context));
    } else if (_error != null && _items == null) {
      body = ErrorView(message: _error!, onRetry: _load);
    } else {
      final items = _items ?? const <SharedItem>[];
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            SharedBanner(expiresAt: g.expiresAt, patientName: g.patientName),
            Text(
              '${g.scope.text}${g.purpose.isEmpty ? '' : ' · ${g.purpose}'} · shared ${formatDateTime(g.createdAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (_error != null) ErrorBanner(_error),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: Text('No records match this share yet.')),
              ),
            for (final i in items)
              Card(
                child: ListTile(
                  key: ValueKey('item-${i.id}'),
                  title: Text(i.title.isEmpty ? i.categoryLabel : i.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${i.categoryLabel} · ${i.date}${i.clinicName == null ? '' : ' · ${i.clinicName}'}'),
                      ProvenanceBadge(i.provenance),
                    ],
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openItem(i),
                ),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(g.patientName)),
      body: body,
    );
  }
}

class SharedEncounterPage extends StatefulWidget {
  const SharedEncounterPage({super.key, required this.api, required this.grant, required this.itemId});
  final SharedApi api;
  final SharedGrant grant;
  final String itemId;

  @override
  State<SharedEncounterPage> createState() => _SharedEncounterPageState();
}

class _SharedEncounterPageState extends State<SharedEncounterPage> {
  SharedEncounter? _enc;
  String? _error;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final e = await widget.api.encounter(widget.grant.id, widget.itemId);
      if (mounted) setState(() => _enc = e);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (isGone(e)) {
          _gone = true;
        } else {
          _error = errorMessage(e);
        }
      });
    }
  }

  Widget _section(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        Text(value.isEmpty ? '-' : value),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final e = _enc;
    Widget body;
    if (_gone) {
      body = _GoneView(onBackToList: () => Navigator.maybePop(context));
    } else if (_error != null) {
      body = ErrorView(message: _error!, onRetry: _load);
    } else if (e == null) {
      body = const LoadingView();
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SharedBanner(expiresAt: widget.grant.expiresAt, patientName: widget.grant.patientName),
          ProvenanceBadge(e.provenance),
          const SizedBox(height: 8),
          Text(
            'Authored by ${e.doctorName} at ${e.clinicName} (version ${e.version}). Only the published summary is shared; private notes and history are never included.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          _section(context, 'Chief complaint', e.chiefComplaint),
          _section(context, 'Diagnosis', e.diagnosis),
          _section(context, 'Plan', e.plan),
          Text('Prescriptions', style: Theme.of(context).textTheme.labelLarge),
          if (e.prescriptions.isEmpty) const Text('-') else for (final r in e.prescriptions) Text('• ${r.text}'),
          if (e.vitals.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [for (final v in e.vitals) Chip(label: Text(v), visualDensity: VisualDensity.compact)],
            ),
          ],
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(e == null ? 'Consultation' : 'Consultation ${e.encounterDate.split('T').first}')),
      body: body,
    );
  }
}

class SharedDocumentPage extends StatefulWidget {
  const SharedDocumentPage({super.key, required this.api, required this.grant, required this.itemId});
  final SharedApi api;
  final SharedGrant grant;
  final String itemId;

  @override
  State<SharedDocumentPage> createState() => _SharedDocumentPageState();
}

class _SharedDocumentPageState extends State<SharedDocumentPage> {
  SharedDocument? _doc;
  final Map<int, String> _links = {};
  String? _error;
  String? _pageError;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _pageError = null;
    });
    try {
      final d = await widget.api.document(widget.grant.id, widget.itemId);
      if (!mounted) return;
      setState(() => _doc = d);
      for (final p in d.pages.take(30)) {
        try {
          final path = await widget.api.pageLink(widget.grant.id, widget.itemId, p.page);
          if (mounted) setState(() => _links[p.page] = '${widget.api.baseUrl}$path');
        } catch (e) {
          if (isGone(e) && mounted) setState(() => _gone = true);
          if (mounted) setState(() => _pageError = isGone(e) ? null : errorMessage(e));
          break;
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (isGone(e)) {
          _gone = true;
        } else {
          _error = errorMessage(e);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _doc;
    Widget body;
    if (_gone) {
      body = _GoneView(onBackToList: () => Navigator.maybePop(context));
    } else if (_error != null) {
      body = ErrorView(message: _error!, onRetry: _load);
    } else if (d == null) {
      body = const LoadingView();
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SharedBanner(expiresAt: widget.grant.expiresAt, patientName: widget.grant.patientName),
          Wrap(
            spacing: 8,
            children: [
              Chip(label: Text(shareCategoryLabels[d.category] ?? d.category), visualDensity: VisualDensity.compact),
              ProvenanceBadge(d.provenance),
            ],
          ),
          Text('${d.date}${d.notes.isEmpty ? '' : ' · ${d.notes}'}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (_pageError != null) ErrorBanner(_pageError),
          if (d.pages.isEmpty) const Text('This document has no pages.'),
          for (final p in d.pages)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _links[p.page] == null
                  ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
                  : p.mime.startsWith('image/')
                  ? Image.network(
                      _links[p.page]!,
                      errorBuilder: (_, _, _) =>
                          Text('Page ${p.page} could not be loaded. The link may have expired; pull down to reload.'),
                    )
                  : Row(
                      children: [
                        const Icon(Icons.insert_drive_file_outlined),
                        const SizedBox(width: 8),
                        Expanded(child: Text('Page ${p.page} (${p.mime}) cannot be previewed here.')),
                        TextButton(
                          onPressed: () => copyToClipboard(context, _links[p.page]!, label: 'Link copied'),
                          child: const Text('Copy link'),
                        ),
                      ],
                    ),
            ),
        ],
      );
      body = RefreshIndicator(onRefresh: _load, child: body);
    }
    return Scaffold(
      appBar: AppBar(title: Text(d == null || d.title.isEmpty ? 'Document' : d.title)),
      body: body,
    );
  }
}
