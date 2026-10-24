import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'clinic_repository.dart';

/// First sign-in without a clinic: doctors register + create a workspace; staff enter an invitation code.
class OnboardingPage extends StatelessWidget {
  const OnboardingPage({super.key, required this.auth, required this.repository});
  final AuthController auth;
  final ClinicRepository repository;

  @override
  Widget build(BuildContext context) {
    final me = auth.me!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Welcome'),
          actions: [TextButton(onPressed: auth.signOut, child: const Text('Sign out'))],
          bottom: const TabBar(tabs: [Tab(text: "I'm a doctor"), Tab(text: 'I have an invitation')]),
        ),
        body: TabBarView(children: [
          _DoctorSetup(auth: auth, repository: repository),
          _AcceptInvite(auth: auth, repository: repository),
        ]),
        bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: Text(me.phone, textAlign: TextAlign.center))),
      ),
    );
  }
}

class _DoctorSetup extends StatefulWidget {
  const _DoctorSetup({required this.auth, required this.repository});
  final AuthController auth;
  final ClinicRepository repository;

  @override
  State<_DoctorSetup> createState() => _DoctorSetupState();
}

class _DoctorSetupState extends State<_DoctorSetup> {
  late final _name = TextEditingController(text: widget.auth.me?.fullName ?? '');
  final _license = TextEditingController();
  final _clinic = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _needsProfile => widget.auth.me?.doctorProfile == null;

  @override
  void dispose() {
    _name.dispose();
    _license.dispose();
    _clinic.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_needsProfile && (_name.text.trim().length < 2 || _license.text.trim().length < 3)) {
      return setState(() => _error = 'Enter your full name and medical licence number.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_needsProfile) await widget.repository.registerDoctor(fullName: _name.text, licenseNumber: _license.text);
      await widget.repository.createWorkspace(name: _clinic.text);
      await widget.auth.reloadMe();
    } catch (e) {
      // A half-done setup (profile saved, workspace failed) must not ask for the licence again.
      if (mounted) {
        try {
          await widget.auth.reloadMe();
        } catch (_) {}
        if (mounted) {
          setState(() {
            _error = errorMessage(e);
            _busy = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => FormPage(children: [
        if (_needsProfile) ...[
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Full name'), textCapitalization: TextCapitalization.words),
          const SizedBox(height: 16),
          TextField(controller: _license, decoration: const InputDecoration(labelText: 'Medical licence number')),
          const SizedBox(height: 16),
        ],
        TextField(controller: _clinic, decoration: const InputDecoration(labelText: 'Clinic name (optional)')),
        if (_error != null) ...[const SizedBox(height: 16), ErrorBanner(_error!)],
        const SizedBox(height: 24),
        BusyButton(label: 'Create my workspace', busy: _busy, onPressed: _submit),
      ]);
}

class _AcceptInvite extends StatefulWidget {
  const _AcceptInvite({required this.auth, required this.repository});
  final AuthController auth;
  final ClinicRepository repository;

  @override
  State<_AcceptInvite> createState() => _AcceptInviteState();
}

class _AcceptInviteState extends State<_AcceptInvite> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_code.text.trim().length < 6) return setState(() => _error = 'Enter the invitation code from your SMS.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.acceptInvitation(_code.text.toUpperCase());
      await widget.auth.reloadMe();
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
  Widget build(BuildContext context) => FormPage(children: [
        const Text('Your clinic sent you a code by SMS. It only works for the phone number it was sent to.'),
        const SizedBox(height: 16),
        TextField(controller: _code, decoration: const InputDecoration(labelText: 'Invitation code'), textCapitalization: TextCapitalization.characters),
        if (_error != null) ...[const SizedBox(height: 16), ErrorBanner(_error!)],
        const SizedBox(height: 24),
        BusyButton(label: 'Join clinic', busy: _busy, onPressed: _submit),
      ]);
}
