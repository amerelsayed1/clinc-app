import 'package:flutter/material.dart';

import '../../feature.dart';
import '../../permissions.dart';
import 'team_api.dart';
import 'team_page.dart';

void registerTeam(FeatureRegistry registry) {
  registry.add(ClinicFeature(
    id: 'team',
    label: 'Team',
    icon: Icons.groups_outlined,
    selectedIcon: Icons.groups,
    requiredPermission: Perm.staffManage,
    order: 50,
    builder: (context, session) => TeamPage(api: TeamApi(session.api)),
  ));
}
