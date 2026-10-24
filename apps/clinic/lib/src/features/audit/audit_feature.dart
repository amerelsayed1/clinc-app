import 'package:flutter/material.dart';

import '../../feature.dart';
import '../../permissions.dart';
import 'audit_api.dart';
import 'audit_page.dart';

void registerAudit(FeatureRegistry registry) {
  registry.add(
    ClinicFeature(
      id: 'audit',
      label: 'Audit log',
      icon: Icons.fact_check_outlined,
      requiredPermission: Perm.auditRead,
      inBottomBar: false,
      order: 70,
      builder: (context, session) => AuditPage(api: AuditApi(session.api), canListStaff: session.can(Perm.staffManage)),
    ),
  );
}
