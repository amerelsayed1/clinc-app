import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'patient_repository.dart';
import 'sharing_models.dart';
import 'sharing_page.dart' show retentionNotice;

/// Create a share: recipient, what, how long, why, acknowledgements.
class ShareFormPage extends StatefulWidget {
  const ShareFormPage({super.key, required this.repository});
  final PatientRepository repository;

  @override
  State<ShareFormPage> createState() => _ShareFormPageState();
}

class _ShareFormPageState extends State<ShareFormPage> {
  List<Relationship>? _clinics;
  List<ShareableItem>? _shareable;
  String? _loadError;

  bool _byPhone = false;
  String? _relationshipId;
  final _phone = TextEditingController();
  bool _byItems = false;
  final Set<ItemRef> _items = {};
  final Set<String> _categories = {};
  String? _from, _to;
  int _days = defaultShareDays;
  final _purpose = TextEditingController();
  bool _ackRetention = false;
  bool _ackSensitive = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    _purpose.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = await widget.repository.relationships();
      final s = await widget.repository.shareable();
      if (!mounted) return;
      setState(() {
        _clinics = c.where((r) => r.isActive).toList();
        _shareable = s;
        _byPhone = _clinics!.isEmpty;
        _loadError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = errorMessage(e));
    }
  }

  ShareScope? get _scope => buildScope(byItems: _byItems, items: _items, categories: _categories, from: _from, to: _to);

  Map<String, dynamic> get _recipient => _byPhone ? {'doctorPhone': _phone.text.trim()} : {'relationshipId': _relationshipId};

  void _clampDays() {
    final max = maxDaysFor(_scope);
    if (_days > max) _days = max;
  }

  Future<void> _pickDate(bool from) async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: now, firstDate: DateTime(1990), lastDate: now);
    if (d != null) setState(() => from ? _from = formatDate(d) : _to = formatDate(d));
  }

  Future<void> _submit() async {
    final scope = _scope;
    final hasRecipient = _byPhone ? isValidPhone(_phone.text.trim()) : _relationshipId != null;
    final problem = validateShare(scope: scope, days: _days, hasRecipient: hasRecipient, ackRetention: _ackRetention, ackSensitive: _ackSensitive);
    if (problem != null) {
      setState(() => _error = _byPhone && !hasRecipient && _phone.text.isNotEmpty ? 'Enter the doctor\'s phone number in international format, e.g. +201000000000.' : problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.createGrant({
        'recipient': _recipient,
        'scope': scope!.toJson(),
        'days': _days,
        'purpose': _purpose.text.trim(),
        'acknowledgeRetention': _ackRetention,
        if (scope.sensitive) 'acknowledgeSensitive': _ackSensitive,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = shareErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Share records')),
      body: _clinics == null || _shareable == null
          ? (_loadError != null ? ErrorView(message: _loadError!, onRetry: _load) : const LoadingView())
          : FormPage(children: _form(context)),
    );
  }

  List<Widget> _form(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scope = _scope;
    final max = maxDaysFor(scope);
    final sensitive = scope?.sensitive ?? false;
    final visible = _shareable!;
    return [
      Text('Who can see them?', style: t.titleMedium),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        segments: [
          ButtonSegment(value: false, label: const Text('My clinics'), enabled: _clinics!.isNotEmpty),
          const ButtonSegment(value: true, label: Text('Doctor by phone')),
        ],
        selected: {_byPhone},
        onSelectionChanged: (s) => setState(() => _byPhone = s.first),
      ),
      const SizedBox(height: 8),
      if (_byPhone)
        TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Doctor phone number', hintText: '+201000000000', helperText: 'The doctor must be registered and verified on CareLink.'))
      else
        DropdownButtonFormField<String>(
          initialValue: _relationshipId,
          decoration: const InputDecoration(labelText: 'Clinic'),
          items: [for (final r in _clinics!) DropdownMenuItem(value: r.id, child: Text('${r.doctorName ?? 'Doctor'} - ${r.workspaceName}'))],
          onChanged: (v) => setState(() => _relationshipId = v),
        ),
      const SizedBox(height: 24),
      Text('What do you want to share?', style: t.titleMedium),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        segments: const [ButtonSegment(value: false, label: Text('Categories')), ButtonSegment(value: true, label: Text('Specific items'))],
        selected: {_byItems},
        onSelectionChanged: (s) => setState(() {
          _byItems = s.first;
          _clampDays();
        }),
      ),
      const SizedBox(height: 8),
      if (_byItems) ...[
        if (visible.isEmpty) const Text('You have no records that can be shared yet.'),
        for (final i in visible)
          CheckboxListTile(
            key: Key('item-${i.id}'),
            contentPadding: EdgeInsets.zero,
            value: _items.contains(i.ref),
            title: Text(i.title),
            subtitle: Text('${i.date} - ${i.type == 'encounter' ? 'Consultation' : categoryLabel(i.category)}${i.clinicName != null ? ' - ${i.clinicName}' : ''}'),
            onChanged: (v) => setState(() {
              v == true ? _items.add(i.ref) : _items.remove(i.ref);
              _clampDays();
            }),
          ),
      ] else ...[
        Wrap(spacing: 8, children: [
          for (final c in shareCategories)
            FilterChip(
              label: Text(categoryLabel(c)),
              selected: _categories.contains(c),
              onSelected: (v) => setState(() {
                v ? _categories.add(c) : _categories.remove(c);
                _clampDays();
              }),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => _pickDate(true), child: Text(_from == null ? 'From (optional)' : 'From $_from'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: () => _pickDate(false), child: Text(_to == null ? 'To (optional)' : 'To $_to'))),
        ]),
        if (_from != null || _to != null) TextButton(onPressed: () => setState(() => _from = _to = null), child: const Text('Clear dates')),
      ],
      if (sensitive)
        Card(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          margin: const EdgeInsets.only(top: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Consultation records are sensitive', style: t.titleSmall),
              const Text('They can be shared for at most $sensitiveMaxDays days at a time.'),
              CheckboxListTile(
                key: const Key('ack-sensitive'),
                contentPadding: EdgeInsets.zero,
                value: _ackSensitive,
                onChanged: (v) => setState(() => _ackSensitive = v == true),
                title: const Text('I want to share my consultation records.'),
              ),
            ]),
          ),
        ),
      const SizedBox(height: 24),
      Text('For how long? $_days ${_days == 1 ? 'day' : 'days'}', style: t.titleMedium),
      Slider(
        key: const Key('share-days'),
        min: 1,
        max: max.toDouble(),
        divisions: max - 1,
        value: _days.clamp(1, max).toDouble(),
        label: '$_days',
        onChanged: (v) => setState(() => _days = v.round()),
      ),
      Text('Maximum $max days. Access ends automatically.', style: t.bodySmall),
      const SizedBox(height: 16),
      TextField(controller: _purpose, maxLength: 300, decoration: const InputDecoration(labelText: 'Purpose (optional)', hintText: 'e.g. Second opinion')),
      CheckboxListTile(
        key: const Key('ack-retention'),
        contentPadding: EdgeInsets.zero,
        value: _ackRetention,
        onChanged: (v) => setState(() => _ackRetention = v == true),
        title: const Text(retentionNotice),
      ),
      ErrorBanner(_error),
      const SizedBox(height: 12),
      FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Sharing...' : 'Share')),
    ];
  }
}
