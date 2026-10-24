import 'package:flutter/material.dart';

import '../../feature.dart';
import '../../permissions.dart';
import 'settings_page.dart';

void registerSettings(FeatureRegistry registry) {
  registry.add(ClinicFeature(
    id: 'settings',
    label: 'Clinic settings',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune,
    requiredPermission: Perm.staffManage,
    order: 60,
    builder: (context, session) => SettingsPage(api: session.api),
  ));
}
