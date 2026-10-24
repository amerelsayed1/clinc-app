import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import 'feature.dart';
import 'onboarding_page.dart';
import 'session.dart';

/// Post-login gating: load -> mandatory MFA -> onboarding (no clinic yet) -> permission-driven shell.
class ClinicRoot extends StatelessWidget {
  const ClinicRoot({super.key, required this.session, required this.registry});
  final ClinicSession session;
  final FeatureRegistry registry;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final me = session.me;
          if (me == null) return const Scaffold(body: LoadingView());
          if (me.needsMfaEnrolment) return MfaEnrollScreen(controller: session.auth, forced: true);
          if (session.membership == null) return OnboardingPage(auth: session.auth, repository: session.repository);
          return ClinicShell(session: session, registry: registry);
        },
      );
}

/// Licence-verification notices (wording copied from the dashboard).
class VerificationBanner extends StatelessWidget {
  const VerificationBanner({super.key, required this.session});
  final ClinicSession session;

  @override
  Widget build(BuildContext context) {
    final p = session.me?.doctorProfile;
    final scheme = Theme.of(context).colorScheme;
    String? text;
    var error = false;
    if (p?.verificationStatus == 'pending' && session.isDoctor) {
      text = 'Your licence is awaiting verification. Clinical features unlock once it is approved.';
    } else if (p?.verificationStatus == 'rejected') {
      text = 'Your licence verification was rejected: ${p?.verificationNote ?? 'contact support'}.';
      error = true;
    }
    if (text == null) return const SizedBox.shrink();
    return Material(
      key: const ValueKey('verification-banner'),
      color: error ? scheme.errorContainer : scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Icon(error ? Icons.error_outline : Icons.hourglass_top, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ]),
      ),
    );
  }
}

class ClinicShell extends StatefulWidget {
  const ClinicShell({super.key, required this.session, required this.registry});
  final ClinicSession session;
  final FeatureRegistry registry;

  @override
  State<ClinicShell> createState() => _ClinicShellState();
}

class _ClinicShellState extends State<ClinicShell> {
  static const _moreId = '__more__';
  String? _selected; // feature id or _moreId; null = first destination
  final Set<String> _visited = {};

  ClinicSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    // Spec 10: adopt the saved language, register the push token (if consented), load the unread badge.
    session.kit.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybePromptForNotificationConsent(context, session.kit);
    });
  }

  void _select(String id) {
    setState(() => _selected = id);
    session.selectedFeature.value = id == _moreId ? null : id;
    session.kit.unread.refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final layout = NavLayout.compute(widget.registry.visibleFor(session));
          final bottomIds = layout.bottom.map((f) => f.id).toList();
          // Permissions may change under us (reloadMe): fall back to the first destination.
          var current = _selected ?? (bottomIds.isNotEmpty ? bottomIds.first : _moreId);
          if (current == _moreId ? !layout.hasMore : !bottomIds.contains(current)) {
            current = bottomIds.isNotEmpty ? bottomIds.first : _moreId;
          }
          _visited.add(current);
          final index = current == _moreId ? layout.bottom.length : bottomIds.indexOf(current);
          final title = current == _moreId ? 'More' : layout.bottom[index].label;

          return Scaffold(
            appBar: AppBar(
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title),
                if (session.workspaceName != null) Text(session.workspaceName!, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            body: Column(children: [
              VerificationBanner(session: session),
              Expanded(
                child: IndexedStack(index: index, children: [
                  for (final f in layout.bottom) _visited.contains(f.id) ? KeyedSubtree(key: ValueKey(f.id), child: f.builder(context, session)) : const SizedBox.shrink(),
                  if (layout.hasMore) _MoreList(features: layout.more, session: session),
                ]),
              ),
            ]),
            bottomNavigationBar: layout.bottom.isEmpty && !layout.hasMore
                ? null
                : NavigationBar(
                    selectedIndex: index,
                    onDestinationSelected: (i) => _select(i < layout.bottom.length ? layout.bottom[i].id : _moreId),
                    destinations: [
                      for (final f in layout.bottom) _destination(f),
                      if (layout.hasMore) const NavigationDestination(icon: Icon(Icons.menu), label: 'More'),
                    ],
                  ),
          );
        },
      );

  Widget _icon(ClinicFeature f, IconData icon) {
    final b = f.badge?.call(session);
    if (b == null) return Icon(icon);
    return ListenableBuilder(
      listenable: b.listenable,
      builder: (context, _) => Badge(isLabelVisible: b.count() > 0, label: Text(b.count() > 99 ? '99+' : '${b.count()}'), child: Icon(icon)),
    );
  }

  NavigationDestination _destination(ClinicFeature f) => NavigationDestination(
        key: ValueKey('nav-${f.id}'),
        icon: _icon(f, f.icon),
        selectedIcon: _icon(f, f.selectedIcon ?? f.icon),
        label: f.label,
      );
}

class _MoreList extends StatelessWidget {
  const _MoreList({required this.features, required this.session});
  final List<ClinicFeature> features;
  final ClinicSession session;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        for (final f in features)
          Card(
            child: ListTile(
              key: ValueKey('more-${f.id}'),
              leading: Icon(f.icon),
              title: Text(f.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                session.selectedFeature.value = f.id;
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (ctx) => Scaffold(appBar: AppBar(title: Text(f.label)), body: f.builder(ctx, session))))
                    .whenComplete(() => session.selectedFeature.value = null);
              },
            ),
          ),
      ]);
}
