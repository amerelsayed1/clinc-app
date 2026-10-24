import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'admin_repository.dart';

/// F11-3: platform admins can read a clinic's audit log only with a written justification and for a limited time.
/// The grant is written to that clinic's own audit log, where its owner sees it.
class BreakGlassPage extends StatefulWidget {
  const BreakGlassPage({super.key, required this.repository});
  final AdminRepository repository;

  @override
  State<BreakGlassPage> createState() => _BreakGlassPageState();
}

class _BreakGlassPageState extends State<BreakGlassPage> {
  List<WorkspaceSummary>? _clinics;
  List<BreakGlassAccess> _access = const [];
  String? _error;
  String? _clinicId;
  int _minutes = 30;
  bool _busy = false;
  final _why = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _why.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = await widget.repository.workspaces();
      final a = await widget.repository.breakGlassAccess();
      if (mounted) {
        setState(() {
          _clinics = c;
          _access = a;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _grant() async {
    setState(() => _busy = true);
    try {
      await widget.repository.grantBreakGlass(workspaceId: _clinicId!, justification: _why.text, minutes: _minutes);
      _why.clear();
      await _load();
      if (mounted) showSnack(context, 'Access granted for $_minutes minutes. The clinic owner can see this in their audit log.');
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(BreakGlassAccess a) async {
    try {
      await widget.repository.revokeBreakGlass(a.id);
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ErrorView(
        message: _error!,
        onRetry: () {
          setState(() => _error = null);
          _load();
        },
      );
    }
    if (_clinics == null) return const LoadingView();
    final active = _access.where((a) => a.active).toList();
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Break-glass access', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      const Text('Use only to investigate a security or integrity incident. Your justification is recorded in the clinic\'s audit log and visible to its owner.'),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: const Key('clinic-picker'),
        initialValue: _clinicId,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Clinic', border: OutlineInputBorder()),
        items: [for (final c in _clinics!) DropdownMenuItem(value: c.id, child: Text('${c.name} · ${c.ownerName}', overflow: TextOverflow.ellipsis))],
        onChanged: (v) => setState(() => _clinicId = v),
      ),
      const SizedBox(height: 12),
      ListenableBuilder(
        listenable: _why,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _why,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Justification (at least 15 characters)', border: OutlineInputBorder(), alignLabelWithHint: true),
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: const [ButtonSegment(value: 15, label: Text('15 min')), ButtonSegment(value: 30, label: Text('30 min')), ButtonSegment(value: 60, label: Text('60 min'))],
            selected: {_minutes},
            onSelectionChanged: (s) => setState(() => _minutes = s.first),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _clinicId == null || _why.text.trim().length < 15 || _busy ? null : _grant,
            icon: const Icon(Icons.emergency_outlined),
            label: const Text('Open break-glass access'),
          ),
        ]),
      ),
      const SizedBox(height: 24),
      Text('Active access', style: Theme.of(context).textTheme.titleMedium),
      if (active.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('None. Open access above to read a clinic\'s audit log.')),
      for (final a in active)
        Card(
          child: ListTile(
            title: Text(a.workspaceName),
            subtitle: Text('Until ${formatDateTime(a.expiresAt?.toLocal())}\n${a.justification}'),
            isThreeLine: true,
            trailing: Wrap(spacing: 4, children: [
              IconButton(tooltip: 'View audit log', icon: const Icon(Icons.list_alt), onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ClinicAuditViewer(repository: widget.repository, access: a)))),
              IconButton(tooltip: 'End access', icon: const Icon(Icons.close), onPressed: () => _revoke(a)),
            ]),
          ),
        ),
    ]);
  }
}

/// The clinic's audit log, readable while the break-glass window is open. Every load is itself recorded.
class ClinicAuditViewer extends StatefulWidget {
  const ClinicAuditViewer({super.key, required this.repository, required this.access});
  final AdminRepository repository;
  final BreakGlassAccess access;

  @override
  State<ClinicAuditViewer> createState() => _ClinicAuditViewerState();
}

class _ClinicAuditViewerState extends State<ClinicAuditViewer> {
  late Future<List<AuditRow>> _rows = widget.repository.workspaceAudit(widget.access.workspaceId);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.access.workspaceName), actions: [
          IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: () => setState(() => _rows = widget.repository.workspaceAudit(widget.access.workspaceId))),
        ]),
        body: FutureBuilder<List<AuditRow>>(
          future: _rows,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(message: errorMessage(snap.error!));
            if (!snap.hasData) return const LoadingView();
            final rows = snap.data!;
            if (rows.isEmpty) return const Center(child: Text('No entries.'));
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = rows[i];
                return ListTile(
                  dense: true,
                  tileColor: r.breakGlass ? Theme.of(context).colorScheme.errorContainer : null,
                  title: Text(r.action),
                  subtitle: Text('#${r.seq} · ${formatDateTime(r.at?.toLocal())} · ${r.actor}${r.result == 'denied' ? ' · denied' : ''}'),
                );
              },
            );
          },
        ),
      );
}
