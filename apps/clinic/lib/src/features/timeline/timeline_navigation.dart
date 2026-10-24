import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../session.dart';
import '../documents/document_viewer.dart';
import '../documents/documents_api.dart';
import '../documents/format.dart';
import '../patients/encounter_page.dart' show openEncounter;
import 'encounter_read_page.dart';
import 'timeline_api.dart';
import 'timeline_models.dart';

String sharedBanner(SharedMarker s) => '${s.label}${s.expiresAt != null ? ' · until ${formatDay(s.expiresAt)}' : ''}';

/// Opens one of the clinic's own encounters with the full encounter screen (patients/encounter_page.dart).
Future<void> openTimelineEncounter(BuildContext context, ClinicSession session, String id, {String title = 'Consultation'}) =>
    openEncounter(context, session, id);

/// Opens what a timeline entry points at, by refType (prescriptions and vitals point at their encounter).
Future<void> openTimelineEntry(BuildContext context, ClinicSession session, TimelineEntry e) async {
  final grant = e.shared?.via == 'grant' ? e.shared!.grantId : null;
  final nav = Navigator.of(context);
  if (e.refType == 'encounter') {
    if (e.shared != null) {
      if (grant == null) return;
      await nav.push(MaterialPageRoute(
        builder: (_) => EncounterReadPage(title: e.title, banner: sharedBanner(e.shared!), load: () => TimelineApi(session.api).sharedEncounter(grant, e.id)),
      ));
    } else {
      await openTimelineEncounter(context, session, e.id, title: e.title);
    }
  } else if (e.refType == 'document') {
    final docs = DocumentsApi(session.api);
    try {
      final d = grant != null ? await docs.sharedGet(grant, e.id) : await docs.get(e.id);
      await nav.push(MaterialPageRoute(
        builder: (_) => DocumentViewerPage(
          title: d.title.isEmpty ? e.title : d.title,
          pages: d.pages,
          linkFor: (p) => grant != null ? docs.sharedPageLink(grant, e.id, p) : docs.pageLink(e.id, p),
          api: session.api,
        ),
      ));
    } catch (err) {
      if (context.mounted) showSnack(context, errorMessage(err), error: true);
    }
  }
}

bool isTimelineEntryOpenable(TimelineEntry e) {
  final grant = e.shared?.via == 'grant' ? e.shared!.grantId : null;
  if (e.refType == 'encounter') return e.shared == null || grant != null;
  if (e.refType == 'document') return e.shared == null || grant != null;
  return false;
}
