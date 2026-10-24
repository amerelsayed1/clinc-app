import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../feature.dart';
import '../../session.dart';

void registerNotifications(FeatureRegistry registry) {
  registry.add(ClinicFeature(
    id: 'notifications',
    label: 'Inbox',
    icon: Icons.notifications_outlined,
    selectedIcon: Icons.notifications,
    inBottomBar: true,
    order: 30,
    badge: (s) => ClinicBadge(listenable: s.kit.unread, count: () => s.kit.unread.count),
    builder: (context, session) => _Inbox(session: session),
  ));
}

/// Shared notifications inbox; reloads whenever its tab is (re)selected.
class _Inbox extends StatefulWidget {
  const _Inbox({required this.session});
  final ClinicSession session;

  @override
  State<_Inbox> createState() => _InboxState();
}

class _InboxState extends State<_Inbox> {
  final _key = GlobalKey<NotificationInboxViewState>();

  @override
  void initState() {
    super.initState();
    widget.session.selectedFeature.addListener(_onSelect);
  }

  @override
  void dispose() {
    widget.session.selectedFeature.removeListener(_onSelect);
    super.dispose();
  }

  void _onSelect() {
    if (widget.session.selectedFeature.value == 'notifications') _key.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) => NotificationInboxView(key: _key, kit: widget.session.kit);
}
