import 'package:flutter/material.dart';

import '../../feature.dart';
import 'account_page.dart';

void registerAccount(FeatureRegistry registry) {
  registry.add(ClinicFeature(
    id: 'account',
    label: 'Account',
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
    order: 90,
    builder: (context, session) => AccountPage(session: session),
  ));
}
