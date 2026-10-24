import 'package:flutter/widgets.dart';

import '../../session.dart';
import '../followup/followup_tab.dart';

/// Extra widgets shown at the top of the appointments day view (above the booking list).
///
/// SLOT for the follow-up "attention" list: replace the marker below with one entry, e.g.
/// `(context, session) => AttentionList(session: session)`. Entries decide for themselves whether to
/// show (check `session.can(...)`) and return `SizedBox.shrink()` otherwise.
final List<Widget Function(BuildContext context, ClinicSession session)> appointmentHeaderSlots = [
  (context, session) => AttentionList(session: session),
];
