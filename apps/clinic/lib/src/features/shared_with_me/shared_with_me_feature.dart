import 'package:flutter/material.dart';

import '../../feature.dart';
import '../../permissions.dart';
import 'shared_api.dart';
import 'shared_with_me_page.dart';

export 'access_requests_panel.dart' show AccessRequestsPanel;

void registerSharedWithMe(FeatureRegistry registry) {
  registry.add(
    ClinicFeature(
      id: 'shared',
      label: 'Shared with me',
      icon: Icons.folder_shared_outlined,
      requiredPermission: Perm.clinicalRead,
      inBottomBar: false,
      order: 40,
      builder: (context, session) => SharedWithMePage(api: SharedApi(session.api)),
    ),
  );
}
