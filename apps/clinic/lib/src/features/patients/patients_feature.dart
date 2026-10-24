import 'package:flutter/material.dart';

import '../../feature.dart';
import '../../permissions.dart';
import 'patients_page.dart';

void registerPatients(FeatureRegistry registry) {
  registry.add(ClinicFeature(
    id: 'patients',
    label: 'Patients',
    icon: Icons.people_outline,
    selectedIcon: Icons.people,
    requiredPermission: Perm.patientsRead,
    inBottomBar: true,
    order: 20,
    builder: (context, session) => PatientsPage(session: session),
  ));
}
