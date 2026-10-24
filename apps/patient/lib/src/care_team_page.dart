import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'patient_repository.dart';

class CareTeamPage extends StatefulWidget {
  const CareTeamPage({super.key, required this.repository, this.initial});
  final PatientRepository repository;
  final List<Relationship>? initial;

  @override
  State<CareTeamPage> createState() => _CareTeamPageState();
}

class _CareTeamPageState extends State<CareTeamPage> {
  List<Relationship>? _items;
  String? _error;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _items = widget.initial;
    if (_items == null) _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.repository.relationships();
      if (!mounted) return;
      setState(() {
        _items = r;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _act(Relationship r, Future<void> Function(String) action, String done) async {
    setState(() => _busyId = r.id);
    try {
      await action(r.id);
      if (mounted) showSnack(context, done);
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _end(Relationship r) async {
    final ok = await confirmDialog(context,
        title: 'End care relationship?',
        message: 'You will stop sharing with ${r.doctorName ?? r.workspaceName}, and upcoming appointments with them will be cancelled.',
        confirmLabel: 'End relationship',
        destructive: true);
    if (ok) await _act(r, widget.repository.end, 'Relationship ended.');
  }

  @override
  Widget build(BuildContext context) {
    if (_items == null) {
      return _error != null ? ErrorView(message: _error!, onRetry: _load) : const LoadingView();
    }
    final items = [..._items!]..sort((a, b) => _rank(a).compareTo(_rank(b)));
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(children: [
              const SizedBox(height: 80),
              Icon(Icons.medical_services_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              Text('No care team yet', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                child: Text(
                  'When a doctor adds you using your phone number, their invitation will appear here for you to accept. Pull down to refresh.',
                  textAlign: TextAlign.center,
                ),
              ),
              Padding(padding: const EdgeInsets.all(16), child: ErrorBanner(_error)),
            ])
          : ListView(padding: const EdgeInsets.all(16), children: [
              ErrorBanner(_error),
              for (final r in items) _tile(context, r),
            ]),
    );
  }

  static int _rank(Relationship r) => r.isInvited ? 0 : (r.isActive ? 1 : 2);

  Widget _tile(BuildContext context, Relationship r) {
    final t = Theme.of(context).textTheme;
    final busy = _busyId == r.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.doctorName ?? 'Doctor', style: t.titleMedium)),
            _StatusChip(r.status),
          ]),
          const SizedBox(height: 4),
          Text(r.workspaceName, style: t.bodyMedium),
          const SizedBox(height: 4),
          Text(
            r.endedAt != null ? 'Ended ${formatDate(r.endedAt)}' : 'Since ${formatDate(r.createdAt)}',
            style: t.bodySmall,
          ),
          if (r.isInvited) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : () => _act(r, widget.repository.decline, 'Invitation declined.'),
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : () => _act(r, widget.repository.accept, 'Invitation accepted.'),
                  child: const Text('Accept'),
                ),
              ),
            ]),
          ],
          if (r.isActive) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: busy ? null : () => _end(r),
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                child: const Text('End relationship'),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (label, bg, fg) = switch (status) {
      'invited' => ('Invitation', cs.tertiaryContainer, cs.onTertiaryContainer),
      'active' => ('Active', cs.primaryContainer, cs.onPrimaryContainer),
      'declined' => ('Declined', cs.surfaceContainerHighest, cs.onSurfaceVariant),
      _ => ('Ended', cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}
