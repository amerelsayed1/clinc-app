import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import '../documents/documents_tab.dart';
import '../followup/followup_tab.dart';
import '../shared_with_me/access_requests_panel.dart';
import '../timeline/timeline_tab.dart';
import 'encounters_tab.dart';
import 'overview_tab.dart';
import 'patients_models.dart';

/// What a tab of the patient detail page knows about the patient.
class PatientRef {
  const PatientRef({required this.relationshipId, required this.name, required this.status, required this.hasAccount, this.patient});

  /// Care relationship id: the id every `/patients/:id/...` endpoint takes.
  final String relationshipId;
  final String name;

  /// active | invited | ended
  final String status;

  /// The patient has registered in the patient app (a `patients.user_id` exists).
  final bool hasAccount;

  /// The full record (only set when built by the detail page).
  final Patient? patient;

  bool get isEnded => status == 'ended';
  bool get isActive => status == 'active';

  factory PatientRef.fromPatient(Patient p) => PatientRef(relationshipId: p.id, name: p.fullName, status: p.status, hasAccount: p.hasAccount, patient: p);
}

/// One tab of the patient detail page. The page shows only tabs whose [requiredPermissions] the active
/// membership has.
class PatientTab {
  const PatientTab({required this.label, required this.builder, this.requiredPermissions = const []});
  final String label;
  final List<String> requiredPermissions;
  final Widget Function(BuildContext context, ClinicSession session, PatientRef patient) builder;
}

/// Tabs in display order. To add a tab, replace its `// TAB:` marker line with one `PatientTab(...)`
/// entry (and import its widget at the top of this file). Do not reorder other entries.
final List<PatientTab> patientTabs = [
  PatientTab(label: 'Overview', requiredPermissions: const [Perm.patientsRead], builder: (c, s, p) => OverviewTab(session: s, patient: p)),
  PatientTab(label: 'Encounters', requiredPermissions: const [Perm.clinicalRead], builder: (c, s, p) => EncountersTab(session: s, patient: p)),
  PatientTab(label: 'Documents', requiredPermissions: const [Perm.patientsRead], builder: (c, s, p) => DocumentsTab(session: s, patientId: p.relationshipId, ended: p.isEnded)),
  PatientTab(label: 'Timeline', requiredPermissions: const [Perm.clinicalRead], builder: (c, s, p) => TimelineTab(session: s, patientId: p.relationshipId)),
  PatientTab(label: 'Follow-up', requiredPermissions: const [Perm.clinicalRead], builder: (c, s, p) => FollowupTab(session: s, patientId: p.relationshipId, ended: p.isEnded)),
  PatientTab(
    label: 'Sharing',
    requiredPermissions: const [Perm.clinicalRead],
    builder: (c, s, p) => AccessRequestsPanel(s, relationshipId: p.relationshipId, name: p.name, hasAccount: p.hasAccount),
  ),
];
