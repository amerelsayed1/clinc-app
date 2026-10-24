import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import '../documents/format.dart';
import 'followup_api.dart';
import 'followup_models.dart';
import 'plan_form_page.dart';
import 'trend_chart.dart';

/// Follow-up tab of the patient page (port of FollowupSection.tsx). Needs clinical.read (server enforced);
/// creating/editing/closing needs clinical.write and a relationship that has not ended.
class FollowupTab extends StatefulWidget {
  const FollowupTab({super.key, required this.session, required this.patientId, this.ended = false, this.apiOverride});
  final ClinicSession session;
  final String patientId;
  final bool ended;
  final FollowupApi? apiOverride;

  @override
  State<FollowupTab> createState() => _FollowupTabState();
}

class _FollowupTabState extends State<FollowupTab> {
  late final FollowupApi _api = widget.apiOverride ?? FollowupApi(widget.session.api);
  List<FollowupPlan>? _plans;
  String? _error;
  bool _loading = true;
  int _reloads = 0; // bumps to make plan cards refetch

  bool get _canWrite => widget.session.can(Perm.clinicalWrite) && !widget.ended;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _plans == null;
      _error = null;
    });
    try {
      final p = await _api.plans(widget.patientId);
      if (!mounted) return;
      setState(() {
        _plans = p;
        _loading = false;
        _reloads++;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorMessage(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _create() async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PlanFormPage(api: _api, patientId: widget.patientId)));
    if (ok == true) {
      if (mounted) showSnack(context, 'Follow-up plan created');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: _canWrite ? FloatingActionButton.extended(key: const ValueKey('new-plan'), onPressed: _create, icon: const Icon(Icons.add), label: const Text('New follow-up plan')) : null,
      body: _loading
          ? const LoadingView()
          : _error != null && _plans == null
              ? ErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    children: [
                      if (_plans!.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 48), child: Center(child: Text('No follow-up plans.'))),
                      for (final p in _plans!) PlanCard(key: ValueKey('plan-${p.id}-$_reloads'), planId: p.id, api: _api, canWrite: _canWrite, patientId: widget.patientId, onChanged: _load),
                    ],
                  ),
                ),
    );
  }
}

/// One plan with measurements + trend charts, submissions and edit history.
class PlanCard extends StatefulWidget {
  const PlanCard({super.key, required this.planId, required this.api, required this.canWrite, required this.patientId, required this.onChanged});
  final String planId;
  final FollowupApi api;
  final bool canWrite;
  final String patientId;
  final VoidCallback onChanged;

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  FollowupPlan? _plan;
  String? _error;
  String? _actionError;
  List<FollowupVersion>? _history;
  bool _showHistory = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.api.plan(widget.planId);
      if (mounted) setState(() => _plan = p);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _edit() async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PlanFormPage(api: widget.api, patientId: widget.patientId, plan: _plan)));
    if (ok == true) {
      if (mounted) showSnack(context, 'Plan updated');
      widget.onChanged();
    }
  }

  Future<void> _close() async {
    final reason = await showDialog<String>(context: context, builder: (_) => const _CloseDialog());
    if (reason == null) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await widget.api.close(widget.planId, reason);
      widget.onChanged();
    } catch (e) {
      if (mounted) {
        setState(() {
          _actionError = errorMessage(e);
          _busy = false;
        });
      }
    }
  }

  Future<void> _toggleHistory() async {
    setState(() => _showHistory = !_showHistory);
    if (_showHistory && _history == null) {
      try {
        final h = await widget.api.history(widget.planId);
        if (mounted) setState(() => _history = h);
      } catch (e) {
        if (mounted) setState(() => _actionError = errorMessage(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _plan;
    if (_error != null) return Padding(padding: const EdgeInsets.all(8), child: ErrorBanner(_error));
    if (p == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('Plan ${p.startDate} → ${p.endDate ?? 'open-ended'}', style: t.textTheme.titleMedium),
            Chip(label: Text(p.isActive ? 'Active' : 'Closed'), visualDensity: VisualDensity.compact),
          ]),
          Text('v${p.currentVersion}${p.nextVisitDate != null ? ' · next visit ${p.nextVisitDate}' : ''}', style: t.textTheme.bodySmall),
          if (p.closeReason != null && p.closeReason!.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Closed: ${p.closeReason}')),
          if (p.instructions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(p.instructions)),
          const SizedBox(height: 8),
          Text('Values below are reported by the patient and are not verified findings.', style: t.textTheme.bodySmall),
          for (final m in p.activeMeasurements) _MeasurementBlock(plan: p, m: m, api: widget.api),
          const SizedBox(height: 12),
          Text('Submissions', style: t.textTheme.titleSmall),
          if (p.submissions.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Nothing submitted yet.')),
          for (final s in p.submissions) _SubmissionTile(s),
          if (_actionError != null) Padding(padding: const EdgeInsets.only(top: 8), child: ErrorBanner(_actionError)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            if (widget.canWrite && p.isActive) OutlinedButton.icon(key: ValueKey('edit-${p.id}'), onPressed: _busy ? null : _edit, icon: const Icon(Icons.edit_outlined), label: const Text('Edit')),
            if (widget.canWrite && p.isActive) TextButton.icon(key: ValueKey('close-${p.id}'), style: TextButton.styleFrom(foregroundColor: t.colorScheme.error), onPressed: _busy ? null : _close, icon: const Icon(Icons.stop_circle_outlined), label: const Text('Close plan')),
            TextButton.icon(key: ValueKey('history-${p.id}'), onPressed: _toggleHistory, icon: const Icon(Icons.history), label: Text(_showHistory ? 'Hide history' : 'Edit history')),
          ]),
          if (_showHistory) ...[
            const SizedBox(height: 8),
            if (_history == null) const LinearProgressIndicator(),
            for (final v in _history ?? const <FollowupVersion>[])
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('v${v.version} ${v.change} by ${v.editedBy}'),
                subtitle: Text('${formatTs(v.at)}\n${v.instructions.isEmpty ? '(no instructions)' : v.instructions} · ${v.measurementNames.isEmpty ? 'no measurements' : v.measurementNames.join(', ')}'),
                isThreeLine: true,
              ),
          ],
        ]),
      ),
    );
  }
}

class _CloseDialog extends StatefulWidget {
  const _CloseDialog();
  @override
  State<_CloseDialog> createState() => _CloseDialogState();
}

class _CloseDialogState extends State<_CloseDialog> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Close this follow-up plan?'),
        content: TextField(key: const ValueKey('close-reason'), controller: _c, maxLength: 300, decoration: const InputDecoration(labelText: 'Reason (optional)', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('close-confirm'), style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error), onPressed: () => Navigator.pop(context, _c.text.trim()), child: const Text('Close plan')),
        ],
      );
}

class _MeasurementBlock extends StatefulWidget {
  const _MeasurementBlock({required this.plan, required this.m, required this.api});
  final FollowupPlan plan;
  final FollowupMeasurement m;
  final FollowupApi api;

  @override
  State<_MeasurementBlock> createState() => _MeasurementBlockState();
}

class _MeasurementBlockState extends State<_MeasurementBlock> {
  List<TrendPoint>? _points;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.trend(widget.plan.id, widget.m.id).then((p) {
      if (mounted) setState(() => _points = p);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = errorMessage(e));
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final range = m.hasRange ? ' · expected ${m.normalMin == null ? '…' : fmtNum(m.normalMin!)}–${m.normalMax == null ? '…' : fmtNum(m.normalMax!)}' : '';
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(m.name, style: Theme.of(context).textTheme.titleSmall),
          if (m.overdue) const Chip(label: Text('Overdue'), visualDensity: VisualDensity.compact),
        ]),
        Text('${m.unit} · ${m.frequencyLabel}$range', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        if (_error != null)
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
        else if (_points == null)
          const SizedBox(height: 4, child: LinearProgressIndicator())
        else if (_points!.isEmpty)
          const Text('No patient-reported values yet.')
        else
          TrendChart(points: _points!, unit: m.unit, normalMin: m.normalMin, normalMax: m.normalMax),
      ]),
    );
  }
}

class _SubmissionTile extends StatelessWidget {
  const _SubmissionTile(this.s);
  final FollowupSubmission s;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: s.outsideExpectedRange ? Colors.amber.withValues(alpha: 0.15) : null, borderRadius: BorderRadius.circular(8), border: Border.all(color: cs.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${s.measurementName}: ${fmtNum(s.value)} ${s.unit}', style: const TextStyle(fontWeight: FontWeight.w600)),
        if (s.outsideExpectedRange) Text(followupFlagText, style: TextStyle(color: Colors.amber.shade900, fontWeight: FontWeight.w600)),
        if (s.note.isNotEmpty) Text(s.note),
        Text('${formatTs(s.measuredAt)} · patient-reported${s.documentId != null ? ' · attachment' : ''}', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

/// "Follow-up needs attention": patients with overdue measurements (GET /followups/attention).
/// Embed on the appointments screen. Hidden without clinical.read, while loading, on error or when
/// nobody is overdue. [onOpenPatient] gets the care-relationship id.
class AttentionList extends StatefulWidget {
  const AttentionList({super.key, required this.session, this.onOpenPatient, this.apiOverride});
  final ClinicSession session;
  final void Function(String careRelationshipId)? onOpenPatient;
  final FollowupApi? apiOverride;

  @override
  State<AttentionList> createState() => _AttentionListState();
}

class _AttentionListState extends State<AttentionList> {
  List<AttentionEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    if (!widget.session.can(Perm.clinicalRead)) return;
    try {
      final e = await (widget.apiOverride ?? FollowupApi(widget.session.api)).attention();
      if (mounted) setState(() => _entries = e);
    } catch (_) {
      // optional widget: stay quiet
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: cs.tertiaryContainer,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Follow-up needs attention (${_entries.length})', style: Theme.of(context).textTheme.titleSmall?.copyWith(color: cs.onTertiaryContainer)),
        ),
        for (final e in _entries)
          ListTile(
            key: ValueKey('attention-${e.careRelationshipId}'),
            dense: true,
            title: Text(e.patientName),
            subtitle: Text('Overdue: ${e.items.map((i) => '${i.measurementName} (${i.daysOverdue}d)').join(', ')}'),
            trailing: widget.onOpenPatient == null ? null : const Icon(Icons.chevron_right),
            onTap: widget.onOpenPatient == null ? null : () => widget.onOpenPatient!(e.careRelationshipId),
          ),
        const SizedBox(height: 4),
      ]),
    );
  }
}
