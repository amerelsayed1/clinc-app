import 'dart:async';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import 'patient_detail_page.dart';
import 'patient_form_page.dart';
import 'patients_api.dart';
import 'patients_models.dart';
import 'ui_bits.dart';

PillTone statusTone(String status) => switch (status) {
      'active' => PillTone.good,
      'invited' => PillTone.warn,
      _ => PillTone.neutral,
    };

/// Searchable patient list (name, #number, exact phone) with Current/Ended filter and "Register".
class PatientsPage extends StatefulWidget {
  const PatientsPage({super.key, required this.session, this.searchDebounce = const Duration(milliseconds: 300)});
  final ClinicSession session;
  final Duration searchDebounce;

  @override
  State<PatientsPage> createState() => _PatientsPageState();
}

class _PatientsPageState extends State<PatientsPage> {
  static const _page = 25;
  late final PatientsApi _api = PatientsApi(widget.session.api);
  final _search = TextEditingController();
  Timer? _debounce;
  bool _ended = false;
  List<Patient>? _items;
  bool _more = false;
  bool _loadingMore = false;
  String? _error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    try {
      final r = await _api.list(q: _search.text, status: _ended ? 'ended' : 'open', limit: _page);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items = r;
        _more = r.length == _page;
        _error = null;
      });
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    final gen = _gen;
    try {
      final r = await _api.list(q: _search.text, status: _ended ? 'ended' : 'open', limit: _page, offset: _items!.length);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items = [..._items!, ...r];
        _more = r.length == _page;
      });
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce = Timer(widget.searchDebounce, _load);
  }

  Future<void> _register() async {
    final p = await Navigator.of(context).push<Patient>(MaterialPageRoute(builder: (_) => PatientFormPage(api: _api)));
    if (p == null || !mounted) return;
    await openPatient(context, widget.session, p.id);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final canWrite = widget.session.can(Perm.patientsWrite);
    final items = _items;
    return Scaffold(
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(key: const ValueKey('register-patient'), onPressed: _register, icon: const Icon(Icons.person_add_alt_1), label: const Text('Register'))
          : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            key: const ValueKey('patient-search'),
            controller: _search,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Name, patient number (#12) or exact phone (+20…)',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() {
                    _search.clear();
                    _load();
                  })),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: false, label: Text('Current')), ButtonSegment(value: true, label: Text('Ended'))],
              selected: {_ended},
              onSelectionChanged: (v) {
                setState(() {
                  _ended = v.first;
                  _items = null;
                });
                _load();
              },
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _error != null && items == null
                ? ListView(children: [SizedBox(height: 360, child: ErrorView(message: _error!, onRetry: _load))])
                : items == null
                    ? ListView(children: const [SizedBox(height: 240, child: LoadingView())])
                    : items.isEmpty
                        ? ListView(children: [Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(_search.text.trim().isNotEmpty ? 'No matching patients.' : 'No patients yet.')))])
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 88),
                            itemCount: items.length + (_more ? 1 : 0),
                            itemBuilder: (context, i) {
                              if (i == items.length) {
                                return Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Center(child: OutlinedButton(onPressed: _loadingMore ? null : _loadMore, child: const Text('Load more'))),
                                );
                              }
                              final p = items[i];
                              return ListTile(
                                key: ValueKey('patient-${p.id}'),
                                minVerticalPadding: 10,
                                title: Text(p.fullName),
                                subtitle: Text('${patientNo(p.patientNumber)} · ${p.phone}${p.dateOfBirth == null ? '' : ' · ${p.dateOfBirth}'}'),
                                trailing: StatusPill(switch (p.status) { 'invited' => 'Invited', 'active' => 'Active', _ => 'Ended' }, tone: statusTone(p.status)),
                                onTap: () async {
                                  await openPatient(context, widget.session, p.id);
                                  if (mounted) _load();
                                },
                              );
                            },
                          ),
          ),
        ),
      ]),
    );
  }
}
