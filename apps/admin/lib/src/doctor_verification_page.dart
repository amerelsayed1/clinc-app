import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'admin_repository.dart';

const _tabs = [('pending', 'Pending'), ('verified', 'Verified'), ('rejected', 'Rejected')];

class DoctorVerificationPage extends StatefulWidget {
  const DoctorVerificationPage({super.key, required this.repository});
  final AdminRepository repository;

  @override
  State<DoctorVerificationPage> createState() => _DoctorVerificationPageState();
}

class _DoctorVerificationPageState extends State<DoctorVerificationPage> {
  final _refresh = RefreshSignal();

  @override
  void dispose() {
    _refresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: _tabs.length,
        child: Column(children: [
          TabBar(tabs: [for (final t in _tabs) Tab(text: t.$2)]),
          Expanded(
            child: TabBarView(children: [
              for (final t in _tabs) _DoctorList(status: t.$1, repository: widget.repository, refresh: _refresh, onChanged: _refresh.fire),
            ]),
          ),
        ]),
      );
}

/// Tiny notifier so a decision in one tab reloads all tabs.
class RefreshSignal extends ChangeNotifier {
  void fire() => notifyListeners();
}

class _DoctorList extends StatefulWidget {
  const _DoctorList({required this.status, required this.repository, required this.refresh, required this.onChanged});
  final String status;
  final AdminRepository repository;
  final RefreshSignal refresh;
  final VoidCallback onChanged;

  @override
  State<_DoctorList> createState() => _DoctorListState();
}

class _DoctorListState extends State<_DoctorList> with AutomaticKeepAliveClientMixin {
  List<DoctorApplication>? _items;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    widget.refresh.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.refresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.repository.doctors(widget.status);
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  Future<void> _open(DoctorApplication d) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DoctorDetailSheet(doctor: d, repository: widget.repository),
    );
    if (changed == true) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_items == null) {
      return _error != null ? ErrorView(message: _error!, onRetry: _load) : const LoadingView();
    }
    final empty = _items!.isEmpty;
    return RefreshIndicator(
      onRefresh: _load,
      child: empty
          ? ListView(children: [
              const SizedBox(height: 80),
              Icon(Icons.inbox_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text('No ${widget.status} doctors', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
              Padding(padding: const EdgeInsets.all(16), child: ErrorBanner(_error)),
            ])
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _items!.length + (_error != null ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                if (_error != null && i == 0) return ErrorBanner(_error);
                final d = _items![_error != null ? i - 1 : i];
                return Card(
                  child: ListTile(
                    title: Text(d.displayName),
                    subtitle: Text('${d.phone}\nLicence ${d.licenseNumber} - submitted ${formatDate(d.createdAt)}'),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(d),
                  ),
                );
              },
            ),
    );
  }
}

class DoctorDetailSheet extends StatefulWidget {
  const DoctorDetailSheet({super.key, required this.doctor, required this.repository});
  final DoctorApplication doctor;
  final AdminRepository repository;

  @override
  State<DoctorDetailSheet> createState() => _DoctorDetailSheetState();
}

class _DoctorDetailSheetState extends State<DoctorDetailSheet> {
  final _note = TextEditingController();
  bool _rejecting = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _decide(bool verify) async {
    if (!verify && _note.text.trim().isEmpty) {
      setState(() => _error = 'A note is required when rejecting.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.decide(widget.doctor.userId, verify: verify, note: _note.text);
      if (!mounted) return;
      showSnack(context, verify ? 'Doctor verified.' : 'Doctor rejected.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 100, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: SelectableText(value)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final d = widget.doctor;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(d.displayName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          _row('Phone', d.phone),
          _row('Licence', d.licenseNumber),
          _row('Submitted', formatDate(d.createdAt)),
          _row('Status', d.status),
          const SizedBox(height: 16),
          ErrorBanner(_error),
          if (_rejecting) ...[
            TextField(
              controller: _note,
              autofocus: true,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Reason for rejection (required)'),
            ),
            const SizedBox(height: 8),
            BusyButton(label: 'Confirm rejection', destructive: true, busy: _busy, onPressed: () => _decide(false)),
            TextButton(onPressed: _busy ? null : () => setState(() => _rejecting = false), child: const Text('Back')),
          ] else ...[
            if (d.status != 'verified') BusyButton(label: 'Verify', busy: _busy, onPressed: () => _decide(true)),
            if (d.status != 'rejected') ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : () => setState(() => _rejecting = true),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: Theme.of(context).colorScheme.error),
                child: const Text('Reject'),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}
