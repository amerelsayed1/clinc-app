import 'dart:async';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../session.dart';
import '../documents/format.dart';
import 'timeline_api.dart';
import 'timeline_models.dart';
import 'timeline_navigation.dart';

const _icons = <String, IconData>{
  'encounter': Icons.medical_services_outlined,
  'prescription': Icons.medication_outlined,
  'document': Icons.description_outlined,
  'observation': Icons.monitor_heart_outlined,
  'followup': Icons.repeat,
  'appointment': Icons.event_outlined,
  'shared_notice': Icons.share_outlined,
};
const _badges = {'clinician_authored': 'Clinician-authored', 'patient_submitted': 'Patient-submitted', 'reviewed': 'Reviewed by clinician'};

/// Timeline tab of the patient page (port of TimelineSection.tsx): filters, search, cursor pagination.
class TimelineTab extends StatefulWidget {
  const TimelineTab({super.key, required this.session, required this.patientId, this.apiOverride, this.opener});
  final ClinicSession session;
  final String patientId;
  final TimelineApi? apiOverride;

  /// Test hook; defaults to [openTimelineEntry].
  final Future<void> Function(BuildContext, ClinicSession, TimelineEntry)? opener;

  @override
  State<TimelineTab> createState() => _TimelineTabState();
}

class _TimelineTabState extends State<TimelineTab> {
  late final TimelineApi _api = widget.apiOverride ?? TimelineApi(widget.session.api);
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;

  var _filters = const TimelineFilters();
  final List<TimelineEntry> _items = [];
  String? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _moreError;
  int _gen = 0; // invalidates in-flight requests when filters change

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 400) _loadMore();
  }

  Future<void> _reload({bool keepList = false}) async {
    final gen = ++_gen;
    setState(() {
      _loading = !keepList || _items.isEmpty;
      _error = null;
      _moreError = null;
      _loadingMore = false;
    });
    try {
      final p = await _api.page(widget.patientId, _filters);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items
          ..clear()
          ..addAll(p.items);
        _cursor = p.nextCursor;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = errorMessage(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_cursor == null || _loadingMore || _loading) return;
    final gen = _gen;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final p = await _api.page(widget.patientId, _filters, cursor: _cursor);
      if (!mounted || gen != _gen) return;
      final seen = _items.map((e) => e.key).toSet();
      setState(() {
        _items.addAll(p.items.where((e) => !seen.contains(e.key)));
        _cursor = p.nextCursor;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _moreError = errorMessage(e);
        _loadingMore = false;
      });
    }
  }

  void _setFilters(TimelineFilters f) {
    _filters = f;
    _reload();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _setFilters(_filters.copyWith(q: v)));
  }

  Future<void> _pickDate(bool from) async {
    final now = DateTime.now();
    final cur = DateTime.tryParse((from ? _filters.from : _filters.to) ?? '');
    final d = await showDatePicker(context: context, initialDate: cur ?? now, firstDate: DateTime(1900), lastDate: DateTime(now.year + 1));
    if (d == null) return;
    _setFilters(from ? _filters.copyWith(from: formatDate(d)) : _filters.copyWith(to: formatDate(d)));
  }

  void _clear() {
    _search.clear();
    _debounce?.cancel();
    _setFilters(const TimelineFilters());
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: TextField(
          key: const ValueKey('timeline-search'),
          controller: _search,
          onChanged: _onSearch,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search titles and notes', border: OutlineInputBorder(), isDense: true),
        ),
      ),
      SizedBox(
        height: 52,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
          for (final t in timelineTypes.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                key: ValueKey('type-${t.key}'),
                label: Text(t.value),
                selected: _filters.types.contains(t.key),
                onSelected: (on) => _setFilters(_filters.copyWith(types: {..._filters.types}..toggle(t.key, on))),
              ),
            ),
        ]),
      ),
      SizedBox(
        height: 48,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          if (!_filters.isEmpty || _search.text.isNotEmpty)
            Padding(padding: const EdgeInsets.only(right: 8), child: ActionChip(key: const ValueKey('clear-filters'), avatar: const Icon(Icons.clear, size: 18), label: const Text('Clear filters'), onPressed: _clear)),
          for (final (value, label) in const [('', 'All sources'), ('own', 'This clinic'), ('shared', 'Shared with us'), ('patient', 'Added by patient')])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(key: ValueKey('source-$value'), label: Text(label), selected: _filters.source == value, onSelected: (_) => _setFilters(_filters.copyWith(source: value))),
            ),
          ActionChip(key: const ValueKey('date-from'), avatar: const Icon(Icons.event, size: 18), label: Text(_filters.from == null ? 'From' : 'From ${_filters.from}'), onPressed: () => _pickDate(true)),
          const SizedBox(width: 8),
          ActionChip(key: const ValueKey('date-to'), avatar: const Icon(Icons.event, size: 18), label: Text(_filters.to == null ? 'To' : 'To ${_filters.to}'), onPressed: () => _pickDate(false)),
        ]),
      ),
      Expanded(child: _list(context)),
    ]);
  }

  Widget _list(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorView(message: _error!, onRetry: _reload);
    return RefreshIndicator(
      onRefresh: () => _reload(keepList: true),
      child: _items.isEmpty
          ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: const [Padding(padding: EdgeInsets.all(48), child: Center(child: Text('Nothing on the timeline matches.')))])
          : ListView.builder(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              itemCount: _items.length + 1,
              itemBuilder: (context, i) {
                if (i < _items.length) {
                  final e = _items[i];
                  return _EntryCard(
                    entry: e,
                    onTap: isTimelineEntryOpenable(e) ? () => (widget.opener ?? openTimelineEntry)(context, widget.session, e) : null,
                  );
                }
                if (_moreError != null) return ErrorView(message: _moreError!, onRetry: _loadMore);
                if (_loadingMore) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                if (_cursor != null) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Center(child: OutlinedButton(key: const ValueKey('timeline-more'), onPressed: _loadMore, child: const Text('Load more'))),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
    );
  }
}

extension on Set<String> {
  void toggle(String v, bool on) => on ? add(v) : remove(v);
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry, this.onTap});
  final TimelineEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final cs = Theme.of(context).colorScheme;
    final who = [
      formatTs(e.date),
      if (e.authorName != null) e.authorName!,
      if (e.sourceKind == 'clinic' && e.sourceName != null) e.sourceName! else if (e.shared == null && e.sourceKind == 'patient') 'Patient',
    ].where((s) => s.isNotEmpty).join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: e.shared != null ? cs.tertiaryContainer.withValues(alpha: 0.35) : null,
      child: InkWell(
        key: ValueKey('tl-${e.key}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(_icons[e.type] ?? Icons.circle_outlined, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 2, children: [
                  Chip(label: Text(timelineTypes[e.type] ?? e.type), visualDensity: VisualDensity.compact),
                  Chip(label: Text(_badges[e.badge] ?? e.badge), visualDensity: VisualDensity.compact, backgroundColor: e.badge == 'patient_submitted' ? cs.tertiaryContainer : null),
                  if (e.amended) Chip(label: Text('v${e.version} · amended'), visualDensity: VisualDensity.compact),
                ]),
                if (e.shared != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      Icon(Icons.share_outlined, size: 16, color: cs.tertiary),
                      const SizedBox(width: 4),
                      Expanded(child: Text(sharedBanner(e.shared!), style: TextStyle(color: cs.tertiary, fontWeight: FontWeight.w600))),
                    ]),
                  ),
                if (e.summary.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(e.summary)),
                Padding(padding: const EdgeInsets.only(top: 4), child: Text(who, style: Theme.of(context).textTheme.bodySmall)),
              ]),
            ),
            if (onTap != null) const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}
