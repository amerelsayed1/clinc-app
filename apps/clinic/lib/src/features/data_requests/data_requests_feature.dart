import 'package:flutter/material.dart';

import '../../feature.dart';
import '../../permissions.dart';
import 'data_requests_api.dart';
import 'data_requests_page.dart';

void registerDataRequests(FeatureRegistry registry) {
  registry.add(
    ClinicFeature(
      id: 'data-requests',
      label: 'Data requests',
      icon: Icons.privacy_tip_outlined,
      requiredPermission: Perm.staffManage,
      alsoRequires: const [Perm.clinicalRead],
      inBottomBar: false,
      order: 80,
      builder: (context, session) => DataRequestsPage(
        api: DataRequestsApi(session.api),
        canDecide: session.can(Perm.clinicalWrite),
        canViewRetention: session.can(Perm.auditRead),
        canLiftHold: session.can(Perm.relationshipsManage),
      ),
    ),
  );
}
