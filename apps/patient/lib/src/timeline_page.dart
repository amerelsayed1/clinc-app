import 'dart:async';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'patient_repository.dart';
import 'timeline_detail.dart';
import 'timeline_models.dart';

const _typeIcons = <String, IconData>{
  'encounter': Icons.medical_services_outlined,
  'prescription': Icons.medication_outlined,
  'document': Icons.description_outlined,
  'observation': Icons.monitor_heart_outlined,
  'followup': Icons.repeat,
  'appointment': Icons.event_outlined,
  'shared_notice': Icons.share_outlined,
};

/// "History" tab: everything across all my doctors plus my own uploads, newest first, loaded page by page.
class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key, required this.repository, this.pageSize = 30});
  final PatientRepository repository;
  final int pageSize;

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final List<TimelineEntry> _items = [];
  final Map<String, String> _clinics = {}; // workspaceId -> name, learned from loaded entries
  TimelineFilters _filters = const TimelineFilters();
  String? _cursor;
  bool _loading = false;
  bool _loadedOnce = false;
  String? _error;
  int _generation = 0; // discards responses from superseded filter states
  Timer? _debounce;

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
    if (_cursor != null && !_loading && _scroll.position.pixels > _scroll.position.maxScrollExtent - 300) _loadMore();
  }

  Future<void> _reload() async {
    final gen = ++_generation;
    setState(() {
      _items.clear();
      _cursor = null;
      _error = null;
      _loading = true;
      _loadedOnce = false;
    });
    await _fetch(gen, null);
  }

  Future<void> _loadMore() async {
    final gen = _generation;
    setState(() => _loading = true);
    await _fetch(gen, _cursor);
  }

  Future<void> _fetch(int gen, String? cursor) async {
    try {
      final r = await widget.repository.timeline(_filters, cursor: cursor, limit: widget.pageSize);
      if (!mounted || gen != _generation) return;
      setState(() {
        _items.addAll(r.items);
        for (final e in r.items) {
          if (e.workspaceId != null && e.clinicName != null) _clinics[e.workspaceId!] = e.clinicName!;
        }
        _cursor = r.nextCursor;
        _error = null;
        _loading = false;
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = errorMessage(e);
        _loading = false;
        _loadedOnce = true;
      });
    }
  }

  void _apply(TimelineFilters f) {
    _filters = f;
    _reload();
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1950),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _filters.from != null && _filters.to != null ? DateTimeRange(start: _filters.from!, end: _filters.to!) : null,
    );
    if (r != null) _apply(_filters.copyWith(from: r.start, to: r.end));
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: TextField(
          controller: _search,
          decoration: InputDecoration(
            hintText: 'Search my history',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _search.clear();
                      _apply(_filters.copyWith(query: ''));
                    }),
          ),
          textInputAction: TextInputAction.search,
          onChanged: (v) {
            setState(() {});
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 350), () => _apply(_filters.copyWith(query: v)));
          },
        ),
      ),
      SizedBox(
        height: 52,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final t in timelineTypes.entries)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 8, bottom: 8),
              child: FilterChip(
                label: Text(t.value),
                selected: _filters.types.contains(t.key),
                onSelected: (on) {
                  final next = {..._filters.types};
                  on ? next.add(t.key) : next.remove(t.key);
                  _apply(_filters.copyWith(types: next));
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 8, bottom: 8),
            child: ActionChip(
              avatar: const Icon(Icons.date_range, size: 18),
              label: Text(_filters.from == null ? 'Dates' : '${formatDate(_filters.from)} to ${formatDate(_filters.to)}'),
              onPressed: _pickRange,
            ),
          ),
          if (_filters.from != null)
            Padding(padding: const EdgeInsets.only(right: 6, top: 8, bottom: 8), child: ActionChip(label: const Text('Clear dates'), onPressed: () => _apply(_filters.copyWith(clearDates: true)))),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          const Text('Source: '),
          DropdownButton<String?>(
            value: _filters.workspaceId,
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem(value: null, child: Text('All')),
              const DropdownMenuItem(value: 'patient', child: Text('My uploads')),
              for (final c in _clinics.entries) DropdownMenuItem(value: c.key, child: Text(c.value)),
            ],
            onChanged: (v) => _apply(_filters.copyWith(workspaceId: v, clearSource: v == null)),
          ),
          const Spacer(),
          if (!_filters.isEmpty)
            TextButton(
              onPressed: () {
                _search.clear();
                _apply(const TimelineFilters());
              },
              child: const Text('Clear filters'),
            ),
        ]),
      ),
      Expanded(child: _body()),
    ]);
  }

  Widget _body() {
    if (!_loadedOnce && _error == null) return const LoadingView();
    if (_items.isEmpty && _error != null) return ErrorView(message: _error!, onRetry: _reload);
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_filters.isEmpty ? 'Nothing here yet. Visits, prescriptions and documents from your doctors will appear in your history.' : 'Nothing matches these filters.', textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _items.length + (_cursor != null || _loading || _error != null ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < _items.length) return _EntryTile(entry: _items[i], repository: widget.repository);
          if (_error != null) {
            return ListTile(title: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)), trailing: TextButton(onPressed: _loadMore, child: const Text('Retry')));
          }
          return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.repository});
  final TimelineEntry entry;
  final PatientRepository repository;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey(entry.key),
      leading: CircleAvatar(child: Icon(_typeIcons[entry.type] ?? Icons.circle_outlined)),
      title: Text(entry.title),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (entry.summary.isNotEmpty) Text(entry.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text('${formatDate(entry.date.toLocal())} · ${entry.provenanceLabel}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 2, children: [
          Chip(label: Text(entry.typeLabel), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
          Chip(
            label: Text(entry.badgeLabel),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            backgroundColor: entry.provenance == Provenance.clinician ? null : scheme.tertiaryContainer,
          ),
          if (entry.amended) Chip(label: Text('Updated · version ${entry.version}'), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
        ]),
      ]),
      isThreeLine: true,
      onTap: () => openTimelineEntry(context, repository, entry),
    );
  }
}
