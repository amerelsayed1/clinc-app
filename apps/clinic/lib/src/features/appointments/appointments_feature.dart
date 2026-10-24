import 'package:flutter/material.dart';

import '../../feature.dart';
import '../../permissions.dart';
import 'appointments_page.dart';

void registerAppointments(FeatureRegistry registry) {
  registry.add(ClinicFeature(
    id: 'appointments',
    label: 'Appointments',
    icon: Icons.event_outlined,
    selectedIcon: Icons.event,
    requiredPermission: Perm.appointmentsRead,
    inBottomBar: true,
    order: 10,
    builder: (context, session) => AppointmentsPage(session: session),
  ));
}
