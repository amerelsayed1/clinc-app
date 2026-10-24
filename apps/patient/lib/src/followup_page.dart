import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'followup_models.dart';
import 'patient_repository.dart';

/// Lets the patient choose a photo. Injectable so tests do not need a platform plugin.
typedef AttachmentPicker = Future<PickedAttachment?> Function(BuildContext context);

Future<PickedAttachment?> pickPhotoAttachment(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Take a photo'), onTap: () => Navigator.pop(ctx, ImageSource.camera)),
        ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from gallery'), onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
      ]),
    ),
  );
  if (source == null) return null;
  final x = await ImagePicker().pickImage(source: source, maxWidth: 2200, imageQuality: 85);
  if (x == null) return null;
  return PickedAttachment(await x.readAsBytes(), x.name.isEmpty ? 'photo.jpg' : x.name);
}

/// "Follow-up" tab: plans my doctors asked me to report on, what is due, and a way to report.
class FollowupPage extends StatefulWidget {
  const FollowupPage({super.key, required this.repository, this.pickAttachment = pickPhotoAttachment, this.onDueChanged});
  final PatientRepository repository;
  final AttachmentPicker pickAttachment;
  final ValueChanged<int>? onDueChanged;

  @override
  State<FollowupPage> createState() => _FollowupPageState();
}

class _FollowupPageState extends State<FollowupPage> {
  List<FollowupPlan>? _plans;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await widget.repository.followups();
      if (!mounted) return;
      setState(() {
        _plans = p;
        _error = null;
      });
      widget.onDueChanged?.call(p.fold(0, (n, x) => n + x.dueCount));
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _open(FollowupPlan p) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FollowupPlanPage(plan: p, repository: widget.repository, pickAttachment: widget.pickAttachment),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final plans = _plans;
    if (plans == null) return _error != null ? ErrorView(message: _error!, onRetry: _load) : const LoadingView();
    final t = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: plans.isEmpty
          ? ListView(children: [
              const SizedBox(height: 80),
              Icon(Icons.monitor_heart_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              Text('No follow-up requests', textAlign: TextAlign.center, style: t.titleLarge),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                child: Text('When your doctor asks you to report measurements after a visit, they will appear here.', textAlign: TextAlign.center),
              ),
            ])
          : ListView(padding: const EdgeInsets.all(16), children: [
              ErrorBanner(_error),
              for (final p in plans)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    onTap: () => _open(p),
                    title: Text(p.title),
                    subtitle: Text([
                      if (p.nextVisitDate != null) 'Next visit ${p.nextVisitDate}',
                      if (p.isClosed) 'Closed by your doctor' else if (!p.acceptsValues) 'Ended',
                      p.measurements.map((m) => m.name).join(', '),
                    ].where((s) => s.isNotEmpty).join(' · ')),
                    trailing: p.dueCount > 0
                        ? Chip(label: Text('${p.dueCount} due'), backgroundColor: Theme.of(context).colorScheme.tertiaryContainer)
                        : const Icon(Icons.chevron_right),
                  ),
                ),
            ]),
    );
  }
}

class FollowupPlanPage extends StatefulWidget {
  const FollowupPlanPage({super.key, required this.plan, required this.repository, required this.pickAttachment});
  final FollowupPlan plan;
  final PatientRepository repository;
  final AttachmentPicker pickAttachment;

  @override
  State<FollowupPlanPage> createState() => _FollowupPlanPageState();
}

class _FollowupPlanPageState extends State<FollowupPlanPage> {
  late FollowupPlan _plan = widget.plan;
  List<FollowupSubmission>? _history;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = await widget.repository.followups();
      final h = await widget.repository.followupSubmissions(widget.plan.id);
      if (!mounted) return;
      setState(() {
        _plan = all.firstWhere((p) => p.id == widget.plan.id, orElse: () => _plan);
        _history = h;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _report([FollowupMeasurement? m]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => SubmitReadingPage(plan: _plan, initial: m, repository: widget.repository, pickAttachment: widget.pickAttachment),
    ));
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = _plan;
    return Scaffold(
      appBar: AppBar(title: Text(p.title)),
      floatingActionButton: p.acceptsValues && p.measurements.isNotEmpty
          ? FloatingActionButton.extended(onPressed: _report, icon: const Icon(Icons.add), label: const Text('Report a value'))
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
          ErrorBanner(_error),
          if (!p.acceptsValues)
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(p.isClosed ? 'Your doctor closed this follow-up. You can still see what you reported.' : 'This follow-up has ended. You can still see what you reported.'),
              ),
            ),
          if (p.instructions.isNotEmpty) ...[
            Text('Instructions', style: t.titleSmall),
            const SizedBox(height: 4),
            Text(p.instructions),
            const SizedBox(height: 16),
          ],
          if (p.nextVisitDate != null) Padding(padding: const EdgeInsets.only(bottom: 16), child: Text('Next visit: ${p.nextVisitDate}')),
          Text('Please report', style: t.titleSmall),
          for (final m in p.measurements)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${m.name}${m.unit.isEmpty ? '' : ' (${m.unit})'}'),
              subtitle: Text('${m.frequencyLabel}${m.lastSubmittedAt != null ? ' · last reported ${formatDateTime(m.lastSubmittedAt!.toLocal())}' : ''}'),
              trailing: p.acceptsValues
                  ? (m.isDue ? FilledButton(onPressed: () => _report(m), child: const Text('Report')) : TextButton(onPressed: () => _report(m), child: const Text('Add')))
                  : null,
            ),
          const SizedBox(height: 16),
          Text('Your history', style: t.titleSmall),
          const SizedBox(height: 4),
          Text('These are the values you reported. Your doctor reviews them; they are not test results.', style: t.bodySmall),
          if (_history == null)
            const Padding(padding: EdgeInsets.all(24), child: LoadingView())
          else if (_history!.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('Nothing reported yet.'))
          else
            for (final s in _history!)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${s.measurementName}: ${_fmt(s.value)} ${s.unit}'.trim()),
                subtitle: Text('${formatDateTime(s.measuredAt.toLocal())}${s.note.isEmpty ? '' : '\n${s.note}'}'),
                isThreeLine: s.note.isNotEmpty,
                trailing: s.hasAttachment ? const Icon(Icons.attach_file) : null,
              ),
        ]),
      ),
    );
  }
}

String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

class SubmitReadingPage extends StatefulWidget {
  const SubmitReadingPage({super.key, required this.plan, required this.repository, required this.pickAttachment, this.initial});
  final FollowupPlan plan;
  final FollowupMeasurement? initial;
  final PatientRepository repository;
  final AttachmentPicker pickAttachment;

  @override
  State<SubmitReadingPage> createState() => _SubmitReadingPageState();
}

class _SubmitReadingPageState extends State<SubmitReadingPage> {
  late FollowupMeasurement _m = widget.initial ?? widget.plan.measurements.first;
  final _value = TextEditingController();
  final _note = TextEditingController();
  DateTime _at = DateTime.now();
  PickedAttachment? _file;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final d = await showDatePicker(context: context, initialDate: _at, firstDate: DateTime.now().subtract(const Duration(days: 90)), lastDate: DateTime.now());
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_at));
    if (t == null) return;
    setState(() => _at = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _attach() async {
    try {
      final f = await widget.pickAttachment(context);
      if (f != null && mounted) setState(() => _file = f);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open the photo. ${errorMessage(e)}');
    }
  }

  Future<void> _submit() async {
    final bad = validateReading(valueText: _value.text, measuredAt: _at);
    if (bad != null) return setState(() => _error = bad);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final docId = _file == null ? null : await widget.repository.uploadAttachment(_file!);
      await widget.repository.submitFollowup(widget.plan.id, measurementId: _m.id, value: parseReading(_value.text)!, measuredAt: _at, note: _note.text, documentId: docId);
      if (!mounted) return;
      showSnack(context, 'Reported. Your doctor will review it.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = followupErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Report a value')),
        body: FormPage(children: [
          ErrorBanner(_error),
          if (widget.plan.measurements.length > 1)
            DropdownButtonFormField<String>(
              initialValue: _m.id,
              decoration: const InputDecoration(labelText: 'Measurement'),
              items: [for (final m in widget.plan.measurements) DropdownMenuItem(value: m.id, child: Text(m.name))],
              onChanged: (id) => setState(() => _m = widget.plan.measurements.firstWhere((m) => m.id == id)),
            )
          else
            Text(_m.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          TextField(
            controller: _value,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: InputDecoration(labelText: 'Value', suffixText: _m.unit),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: const Text('Measured at'),
            subtitle: Text(formatDateTime(_at)),
            trailing: TextButton(onPressed: _pickTime, child: const Text('Change')),
          ),
          TextField(controller: _note, maxLength: 500, maxLines: 3, decoration: const InputDecoration(labelText: 'Note (optional)')),
          const SizedBox(height: 8),
          if (_file == null)
            OutlinedButton.icon(onPressed: _attach, icon: const Icon(Icons.photo_camera_outlined), label: const Text('Add a photo (optional)'))
          else
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.attach_file),
              title: Text(_file!.name, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Will be sent to your doctor with this value'),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _file = null)),
            ),
          const SizedBox(height: 24),
          BusyButton(label: 'Send to my doctor', busy: _busy, onPressed: _submit),
        ]),
      );
}
