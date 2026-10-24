import 'dart:convert';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'audit_api.dart';
import 'audit_models.dart';

/// Hands the exported JSON to the system share sheet. Injectable for tests.
typedef AuditSharer = Future<void> Function(String filename, String json);

Future<void> shareAuditJson(String filename, String json) => SharePlus.instance.share(
  ShareParams(
    files: [XFile.fromData(utf8.encode(json), mimeType: 'application/json', name: filename)],
    fileNameOverrides: [filename],
    title: 'Audit log',
  ),
);

/// Filterable, tamper-evident audit log with infinite scroll, integrity check and export.
class AuditPage extends StatefulWidget {
  const AuditPage({super.key, required this.api, this.canListStaff = false, this.sharer = shareAuditJson});
  final AuditApi api;

  /// Whether the "who" filter can load the member list (needs `staff.manage`).
  final bool canListStaff;
  final AuditSharer sharer;

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  final _scroll = ScrollController();
  final List<AuditEntry> _entries = [];
  AuditFilters _filters = const AuditFilters();
  List<StaffRef> _staff = const [];
  String? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _verifying = false;
  bool _exporting = false;
  ChainStatus? _chain;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _more();
    });
    _load();
    if (widget.canListStaff) {
      widget.api
          .staff()
          .then((s) {
            if (mounted) setState(() => _staff = s);
          })
          .catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _entries.isEmpty;
      _error = null;
    });
    try {
      final page = await widget.api.list(_filters);
      if (!mounted) return;
      setState(() {
        _entries
          ..clear()
          ..addAll(page);
        _hasMore = page.length >= AuditApi.pageSize;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    if (_loadingMore || !_hasMore || _loading || _entries.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.api.list(_filters, before: _entries.last.seq);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page);
        _hasMore = page.length >= AuditApi.pageSize;
      });
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _openFilters() async {
    final f = await showModalBottomSheet<AuditFilters>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AuditFilterSheet(initial: _filters, staff: _staff),
    );
    if (f == null || !mounted) return;
    setState(() {
      _filters = f;
      _chain = null;
    });
    await _load();
  }

  Future<void> _verify() async {
    setState(() {
      _verifying = true;
      _actionError = null;
    });
    try {
      final c = await widget.api.verify();
      if (mounted) setState(() => _chain = c);
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _export() async {
    final ok = await confirmDialog(
      context,
      title: 'Export audit log?',
      message: 'Exports up to 5000 entries matching the current filters as a JSON file. The export itself is recorded in the log.',
      confirmLabel: 'Export',
    );
    if (!ok || !mounted) return;
    setState(() {
      _exporting = true;
      _actionError = null;
    });
    try {
      final data = await widget.api.export(_filters);
      final json = const JsonEncoder.withIndent('  ').convert(data);
      await widget.sharer('audit-log-${formatDate(DateTime.now())}.json', json);
      if (mounted) showSnack(context, 'Exported (this export is recorded in the log).');
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final granted = _entries.where((e) => e.action == 'breakglass.granted').length;
    final anyBreakGlass = _entries.any((e) => e.breakGlass);
    Widget body;
    if (_loading) {
      body = const LoadingView();
    } else if (_error != null && _entries.isEmpty) {
      body = ErrorView(message: _error!, onRetry: _load);
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (anyBreakGlass)
              Container(
                key: const ValueKey('breakglass-banner'),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  'Platform support accessed this clinic\'s audit log${granted > 0 ? ' $granted time(s)' : ''}. Each access required a written justification; see the highlighted rows.',
                  style: TextStyle(color: cs.onErrorContainer),
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('verify'),
                  onPressed: _verifying ? null : _verify,
                  icon: _verifying
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.verified_outlined),
                  label: const Text('Verify integrity'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('export'),
                  onPressed: _exporting ? null : _export,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Export JSON'),
                ),
              ],
            ),
            if (_chain != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _chain!.valid ? 'Chain intact (${_chain!.checked} entries)' : 'Tampering detected at entry #${_chain!.brokenAtSeq}',
                  key: const ValueKey('chain-result'),
                  style: TextStyle(color: _chain!.valid ? Colors.green.shade700 : cs.error, fontWeight: FontWeight.w600),
                ),
              ),
            if (_actionError != null) Padding(padding: const EdgeInsets.only(top: 8), child: ErrorBanner(_actionError)),
            const SizedBox(height: 8),
            if (_entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: Text('No entries match.')),
              ),
            for (final e in _entries) _EntryTile(e),
            if (_loadingMore)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!_hasMore && _entries.isNotEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: Text('End of log')),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('filters'),
        onPressed: _openFilters,
        icon: const Icon(Icons.filter_list),
        label: Text(_filters.isEmpty ? 'Filters' : 'Filters (${_filters.activeCount})'),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile(this.e);
  final AuditEntry e;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = e.breakGlass ? cs.errorContainer : (e.denied ? cs.tertiaryContainer : null);
    return Card(
      key: ValueKey('audit-${e.seq}'),
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    e.action,
                    style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600),
                  ),
                ),
                if (e.breakGlass) const Chip(label: Text('break-glass'), visualDensity: VisualDensity.compact),
                if (e.denied) const Chip(label: Text('denied'), visualDensity: VisualDensity.compact),
              ],
            ),
            Text('#${e.seq} · ${formatDateTime(e.createdAt)}', style: Theme.of(context).textTheme.bodySmall),
            Text(e.actorLabel),
            if (e.ip != null) Text(e.ip!, style: Theme.of(context).textTheme.bodySmall),
            if (e.details.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(e.details, style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

class AuditFilterSheet extends StatefulWidget {
  const AuditFilterSheet({super.key, required this.initial, required this.staff});
  final AuditFilters initial;
  final List<StaffRef> staff;

  @override
  State<AuditFilterSheet> createState() => _AuditFilterSheetState();
}

class _AuditFilterSheetState extends State<AuditFilterSheet> {
  late AuditFilters _f = widget.initial;
  late final _target = TextEditingController(text: widget.initial.targetId);

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  Future<void> _pick(bool from) async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: now, firstDate: DateTime(2020), lastDate: now);
    if (d != null) setState(() => _f = from ? _f.copyWith(from: formatDate(d)) : _f.copyWith(to: formatDate(d)));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Filter audit log', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: const ValueKey('f-action'),
              initialValue: _f.action,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final g in auditActionGroups) DropdownMenuItem(value: g.$1, child: Text(g.$2))],
              onChanged: (v) => setState(() => _f = _f.copyWith(action: v ?? '')),
            ),
            if (widget.staff.isNotEmpty)
              DropdownButtonFormField<String>(
                key: const ValueKey('f-actor'),
                initialValue: _f.actor,
                decoration: const InputDecoration(labelText: 'Who'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Anyone')),
                  for (final s in widget.staff) DropdownMenuItem(value: s.userId, child: Text(s.label)),
                ],
                onChanged: (v) => setState(() => _f = _f.copyWith(actor: v ?? '')),
              ),
            DropdownButtonFormField<String>(
              key: const ValueKey('f-result'),
              initialValue: _f.result,
              decoration: const InputDecoration(labelText: 'Result'),
              items: const [
                DropdownMenuItem(value: '', child: Text('Any')),
                DropdownMenuItem(value: 'success', child: Text('Allowed')),
                DropdownMenuItem(value: 'denied', child: Text('Denied')),
              ],
              onChanged: (v) => setState(() => _f = _f.copyWith(result: v ?? '')),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => _pick(true), child: Text(_f.from.isEmpty ? 'From date' : 'From ${_f.from}')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(onPressed: () => _pick(false), child: Text(_f.to.isEmpty ? 'To date' : 'To ${_f.to}')),
                ),
              ],
            ),
            TextField(
              controller: _target,
              decoration: const InputDecoration(labelText: 'Record id', hintText: 'patient / encounter / document id'),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('f-clear'),
                    onPressed: () => Navigator.pop(context, const AuditFilters()),
                    child: const Text('Clear'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('f-apply'),
                    onPressed: () => Navigator.pop(context, _f.copyWith(targetId: _target.text.trim())),
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
