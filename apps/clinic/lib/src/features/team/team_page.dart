import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import 'team_api.dart';
import 'team_models.dart';

/// Members, per-permission deny toggles, suspend/remove, staff invitations (port of dashboard TeamPage).
class TeamPage extends StatefulWidget {
  const TeamPage({super.key, required this.api});
  final TeamApi api;

  @override
  State<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends State<TeamPage> {
  List<Member>? _members;
  List<Invitation> _invites = const [];
  String? _error; // load failure
  String? _actionError;
  bool _loading = true;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _members == null;
      _error = null;
    });
    try {
      final r = await Future.wait([widget.api.members(), widget.api.invitations()]);
      if (!mounted) return;
      setState(() {
        _members = r[0] as List<Member>;
        _invites = r[1] as List<Invitation>;
        _loading = false;
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

  Future<void> _act(String key, Future<void> Function() fn) async {
    setState(() {
      _busy.add(key);
      _actionError = null;
    });
    try {
      await fn();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<void> _invite() async {
    final issued = await showModalBottomSheet<IssuedInvitation>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _InviteSheet(api: widget.api),
    );
    if (issued == null || !mounted) return;
    await _load();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Invitation code'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Shown only once. It was also sent by SMS. It works only for the invited phone number.'),
          const SizedBox(height: 12),
          SelectableText(issued.code, style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(letterSpacing: 2)),
        ]),
        actions: [
          TextButton(onPressed: () => copyToClipboard(ctx, issued.code, label: 'Code copied'), child: const Text('Copy')),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(0, 40)), onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const LoadingView()
        : _error != null && _members == null
            ? ErrorView(message: _error!, onRetry: _load)
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
                  if (_actionError != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: ErrorBanner(_actionError!)),
                  for (final m in _members ?? const <Member>[]) _MemberCard(member: m, busy: _busy.contains(m.id), api: widget.api, act: _act),
                  if (_invites.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('Pending invitations', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final i in _invites)
                      Card(
                        child: ListTile(
                          title: Text(i.phone),
                          subtitle: Text('${roleLabel(i.role)} · expires ${formatDate(i.expiresAt)}'),
                          trailing: TextButton(
                            onPressed: _busy.contains(i.id) ? null : () => _act(i.id, () => widget.api.revokeInvitation(i.id)),
                            child: const Text('Revoke'),
                          ),
                        ),
                      ),
                  ],
                ]),
              );
    return Scaffold(
      body: body,
      floatingActionButton: FloatingActionButton.extended(onPressed: _invite, icon: const Icon(Icons.person_add_alt_1), label: const Text('Invite staff')),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member, required this.busy, required this.api, required this.act});
  final Member member;
  final bool busy;
  final TeamApi api;
  final Future<void> Function(String key, Future<void> Function() fn) act;

  @override
  Widget build(BuildContext context) {
    final m = member;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ExpansionTile(
        key: PageStorageKey('member-${m.id}'),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: CircleAvatar(child: Icon(m.isOwner ? Icons.medical_services_outlined : Icons.person_outline)),
        title: Text(m.displayName),
        subtitle: Text('${roleLabel(m.role)} · ${m.phone}'),
        trailing: Chip(
          label: Text(m.isActive ? 'Active' : 'Suspended'),
          backgroundColor: m.isActive ? null : scheme.errorContainer,
          visualDensity: VisualDensity.compact,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.isOwner)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Owner - all permissions'))
          else ...[
            Text('Permissions', style: Theme.of(context).textTheme.labelLarge),
            for (final p in m.grantable)
              SwitchListTile(
                key: ValueKey('perm-${m.id}-$p'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(p),
                value: !m.deniedPermissions.contains(p),
                onChanged: busy ? null : (on) => act(m.id, () => api.setDenied(m.id, m.deniedAfterToggle(p, allowed: on))),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton(
                key: ValueKey('status-${m.id}'),
                onPressed: busy ? null : () => act(m.id, () => api.setStatus(m.id, m.isActive ? 'suspended' : 'active')),
                child: Text(m.isActive ? 'Suspend' : 'Reactivate'),
              ),
              OutlinedButton(
                key: ValueKey('remove-${m.id}'),
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                onPressed: busy
                    ? null
                    : () async {
                        final ok = await confirmDialog(context,
                            title: 'Remove ${m.displayName}?', message: 'They lose access to this clinic immediately.', confirmLabel: 'Remove', destructive: true);
                        if (ok) await act(m.id, () => api.remove(m.id));
                      },
                child: const Text('Remove'),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

class _InviteSheet extends StatefulWidget {
  const _InviteSheet({required this.api});
  final TeamApi api;

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final _phone = TextEditingController(text: '+20');
  String _role = 'receptionist';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phone = _phone.text.trim();
    if (!isValidPhone(phone)) {
      setState(() => _error = 'Enter the phone number in international format, e.g. +201001234567');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final issued = await widget.api.invite(phone: phone, role: _role);
      if (mounted) Navigator.pop(context, issued);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorMessage(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Invite staff', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number')),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'receptionist', label: Text('Receptionist')),
              ButtonSegment(value: 'nurse', label: Text('Nurse')),
            ],
            selected: {_role},
            onSelectionChanged: (s) => setState(() => _role = s.first),
          ),
          if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
          const SizedBox(height: 16),
          BusyButton(label: 'Send invitation', busy: _busy, onPressed: _submit),
        ]),
      );
}
