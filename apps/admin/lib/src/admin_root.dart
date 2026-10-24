import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'account_page.dart';
import 'admin_repository.dart';
import 'audit_page.dart';
import 'break_glass_page.dart';
import 'doctor_verification_page.dart';

/// Gating: platform admin only -> MFA enrolment forced -> home.
class AdminRoot extends StatelessWidget {
  const AdminRoot({super.key, required this.auth, required this.repository, required this.kit});
  final AuthController auth;
  final AdminRepository repository;
  final NotificationsKit kit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: auth,
        builder: (context, _) {
          final me = auth.me;
          if (me == null) return const Scaffold(body: LoadingView());
          if (!me.isPlatformAdmin) return AccessDeniedScreen(auth: auth);
          if (me.needsMfaEnrolment) return MfaEnrollScreen(controller: auth, forced: true);
          return AdminHome(auth: auth, repository: repository, kit: kit);
        },
      );
}

class AccessDeniedScreen extends StatelessWidget {
  const AccessDeniedScreen({super.key, required this.auth});
  final AuthController auth;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: FormPage(children: [
          const SizedBox(height: 48),
          Icon(Icons.block, size: 56, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 16),
          Text('Access denied', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'This account (${auth.me?.phone ?? ''}) is not a platform administrator.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: auth.signOut, child: const Text('Sign out')),
        ]),
      );
}

class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.auth, required this.repository, required this.kit});
  final AuthController auth;
  final AdminRepository repository;
  final NotificationsKit kit;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  int _index = 0;
  final _inbox = GlobalKey<NotificationInboxViewState>();

  @override
  void initState() {
    super.initState();
    widget.kit.start(); // saved language, push token (if consented), unread badge
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(['Doctor verification', 'Audit integrity', 'Break-glass', CareStrings.of(context).inbox, 'Account'][_index])),
        body: IndexedStack(index: _index, children: [
          DoctorVerificationPage(repository: widget.repository),
          AuditVerificationPage(repository: widget.repository),
          BreakGlassPage(repository: widget.repository),
          NotificationInboxView(key: _inbox, kit: widget.kit),
          AccountPage(auth: widget.auth, kit: widget.kit),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) {
            setState(() => _index = i);
            if (i == 3) _inbox.currentState?.reload();
            widget.kit.unread.refresh();
          },
          destinations: [
            const NavigationDestination(icon: Icon(Icons.verified_outlined), selectedIcon: Icon(Icons.verified), label: 'Doctors'),
            const NavigationDestination(icon: Icon(Icons.fact_check_outlined), selectedIcon: Icon(Icons.fact_check), label: 'Audit'),
            const NavigationDestination(icon: Icon(Icons.emergency_outlined), selectedIcon: Icon(Icons.emergency), label: 'Break-glass'),
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
