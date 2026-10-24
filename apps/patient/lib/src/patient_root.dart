import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'account_page.dart';
import 'care_team_page.dart';
import 'followup_page.dart';
import 'patient_repository.dart';
import 'sharing_models.dart';
import 'sharing_page.dart';
import 'timeline_page.dart';

/// Post-login gating: name -> claim (once per launch, idempotent) -> home.
class PatientRoot extends StatefulWidget {
  const PatientRoot({super.key, required this.auth, required this.repository, required this.kit});
  final AuthController auth;
  final PatientRepository repository;
  final NotificationsKit kit;

  @override
  State<PatientRoot> createState() => _PatientRootState();
}

class _PatientRootState extends State<PatientRoot> {
  List<Relationship>? _initial;
  String? _claimError;
  bool _claiming = false;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_maybeClaim);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeClaim());
  }

  @override
  void dispose() {
    widget.auth.removeListener(_maybeClaim);
    super.dispose();
  }

  Future<void> _maybeClaim() async {
    final me = widget.auth.me;
    if (!mounted || me == null || !me.hasName || _initial != null || _claiming) return;
    setState(() {
      _claiming = true;
      _claimError = null;
    });
    try {
      final rels = await widget.repository.claim();
      if (mounted) setState(() => _initial = rels);
    } catch (e) {
      if (mounted) setState(() => _claimError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) {
        final me = widget.auth.me;
        if (me == null) return const Scaffold(body: LoadingView());
        if (!me.hasName) return NamePromptScreen(auth: widget.auth);
        if (_initial == null) {
          return Scaffold(
            appBar: _claimError == null ? null : AppBar(actions: [TextButton(onPressed: widget.auth.signOut, child: const Text('Sign out'))]),
            body: _claimError != null
                ? ErrorView(message: _claimError!, onRetry: _maybeClaim)
                : const LoadingView(label: 'Setting up your account...'),
          );
        }
        return HomeShell(auth: widget.auth, repository: widget.repository, kit: widget.kit, initial: _initial!);
      },
    );
  }
}

class NamePromptScreen extends StatelessWidget {
  const NamePromptScreen({super.key, required this.auth});
  final AuthController auth;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(actions: [TextButton(onPressed: auth.signOut, child: const Text('Sign out'))]),
        body: FormPage(children: [
          Text('Welcome to CareLink', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('What should your doctor call you? Enter your full name as it appears on your ID.'),
          const SizedBox(height: 24),
          ProfileEditor(controller: auth, submitLabel: 'Continue'),
        ]),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.auth, required this.repository, required this.kit, required this.initial});
  final AuthController auth;
  final PatientRepository repository;
  final NotificationsKit kit;
  final List<Relationship> initial;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  int _pending = 0;
  int _due = 0;
  final _inbox = GlobalKey<NotificationInboxViewState>();

  @override
  void initState() {
    super.initState();
    _refreshPending();
    // Spec 10: adopt the saved language, register the push token (if consented), then ask for
    // consent on first launch. Nothing is sent outside the app until the patient answers (F10-5).
    widget.kit.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybePromptForNotificationConsent(context, widget.kit);
    });
  }

  /// Badge count for the Sharing tab. Failures are ignored; the Sharing tab shows its own errors.
  Future<void> _refreshPending() async {
    try {
      final r = await widget.repository.accessRequests();
      if (mounted) setState(() => _pending = pendingCount(r));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(['Care team', 'Follow-up', 'Sharing', 'History', CareStrings.of(context).inbox, 'Account'][_index])),
        body: IndexedStack(index: _index, children: [
          CareTeamPage(repository: widget.repository, initial: widget.initial),
          FollowupPage(repository: widget.repository, onDueChanged: (n) => setState(() => _due = n)),
          SharingPage(repository: widget.repository, onPendingChanged: (n) => setState(() => _pending = n)),
          TimelinePage(repository: widget.repository),
          NotificationInboxView(key: _inbox, kit: widget.kit),
          AccountPage(auth: widget.auth, kit: widget.kit, repository: widget.repository),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) {
            setState(() => _index = i);
            if (i != 2) _refreshPending();
            if (i == 4) _inbox.currentState?.reload();
            widget.kit.unread.refresh();
          },
          destinations: [
            const NavigationDestination(icon: Icon(Icons.medical_services_outlined), selectedIcon: Icon(Icons.medical_services), label: 'Care team'),
            NavigationDestination(
              icon: Badge(isLabelVisible: _due > 0, label: Text('$_due'), child: const Icon(Icons.monitor_heart_outlined)),
              selectedIcon: Badge(isLabelVisible: _due > 0, label: Text('$_due'), child: const Icon(Icons.monitor_heart)),
              label: 'Follow-up',
            ),
            NavigationDestination(
              icon: Badge(isLabelVisible: _pending > 0, label: Text('$_pending'), child: const Icon(Icons.share_outlined)),
              selectedIcon: Badge(isLabelVisible: _pending > 0, label: Text('$_pending'), child: const Icon(Icons.share)),
              label: 'Sharing',
            ),
            const NavigationDestination(icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history), label: 'History'),
            NavigationDestination(
              icon: UnreadBadge(unread: widget.kit.unread, child: const Icon(Icons.notifications_outlined)),
              selectedIcon: UnreadBadge(unread: widget.kit.unread, child: const Icon(Icons.notifications)),
              label: CareStrings.of(context).inbox,
            ),
            const NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Account'),
          ],
        ),
      );
}
